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

## The theme picker decides, from the registry alone, which of a game's lobby
## tiles are editions of one game — and how the top bar offers them.
const ThemePickerClass := preload("res://src/core/ui/theme_picker.gd")

## The factories every screen builds its tree with, and the shared theme the
## base classes put on the screen itself. By path, for the reason at the top of
## this file.
const UiClass := preload("res://src/core/ui/ui.gd")
const UiThemeClass := preload("res://src/core/ui/ui_theme.gd")

## The action button of every 3D screen. `WorldScreen` builds it by name, so it
## is a fresh class today and `--script` runs do not refresh the class cache.
const TouchButtonClass := preload("res://src/core/ui/touch_button.gd")

## A bare 2D screen to hang the dialog on. The real jumpers are `WorldScreen`s
## built by another scope's files; what is under test here is the core's half,
## and `Screen` is the cheapest host that has a `modal()` and a top bar.
const ScreenClass := preload("res://src/core/ui/screen.gd")

## The one funnel every 3D screen loads its meshes through, and the fire it
## hangs on the meshes that burn. Both by path, for the reason at the top of this
## file — and `WorldScreen` needs the autoloads, so it is only usable from a
## suite that runs after the tree is up.
const WorldScreenClass := preload("res://src/core/ui/world_screen.gd")
const FireGlowClass := preload("res://src/core/ui/fire_glow.gd")

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
	await _telegram_route()
	_legal()
	await _themed_editions()
	_server_address()
	_second_finger()
	_fire()


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
	# The key is not a value the test can predict: it is drawn from the system
	# entropy, so nothing here may spell one out or derive one. What is asserted
	# is the property — the entry that comes back off the disk carries the very
	# key that went onto it, and that key is one the server contract accepts.
	var restored_key := str(reloaded[0].get("clientKey", ""))
	t.check(restored_key.begins_with("s80_"), "Der clientKey von der Platte folgt dem Schema")
	t.check(restored_key.length() > 0 and restored_key.length() <= QueueClass.CLIENT_KEY_MAX,
		"Und passt in das 64-Zeichen-Limit")
	t.equal(restored_key, str(item.get("clientKey", "")),
		"Der clientKey überlebt den Neustart")
	t.equal(str(reloaded[0].get("text", "")), composed, "…und der Text auch")

	# 4. What the bot is handed: the entry itself, with its key. There is no POST
	# body any more — the relay reads `text` and `author` off the queue entry.
	t.equal(str((reloaded[0] as Dictionary).get("text", "")), composed, "Der Eintrag trägt den Text mit Präfix")
	t.equal(str((reloaded[0] as Dictionary).get("author", "")), "Spieler", "…und den Autor")

	# 5. After Telegram confirms, the entry leaves the queue and the file — and it
	# is removed by the key the queue itself holds and just sent, which is the one
	# that came back off the disk. A key the test cannot predict must never be the
	# reason a delivered idea stays in the queue for good.
	t.check(QueueClass.remove(reloaded, restored_key),
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

	# The key is the entry's own: opaque, camelCase, and the thing a retry and a
	# removal look it up by.
	t.check(item.has("clientKey"), "Der Eintrag trägt den clientKey")
	t.equal(str(item.get("clientKey", "")).begins_with("s80_"), true, "…im Schema s80_")

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
	# The key is drawn from the system entropy, so the test never spells one out:
	# the property is that the entry comes back with the key it went onto the disk
	# with, and that the retry sends that very key again.
	var on_disk := str(reloaded[0].get("clientKey", ""))
	t.check(on_disk.begins_with("s80_") and on_disk.length() <= QueueClass.CLIENT_KEY_MAX,
		"Der clientKey von der Platte ist ein gültiger Schlüssel")
	t.equal(on_disk, key, "Der clientKey überlebt den Neustart")
	t.equal(str(reloaded[1].get("text", "")), "Drache mit Feueratem", "…und der Text auch")

	# A retry after the restart has to send the very same key again.
	t.equal(str((reloaded[0] as Dictionary).get("clientKey", "")), key,
		"Der Wiederholungsversuch nutzt denselben clientKey")

	# Removing is a file operation too — otherwise a crash would resurrect it. It
	# happens by the key the queue holds, which is the one that just went out.
	t.check(QueueClass.remove(reloaded, key),
		"Ein zugestellter Vorschlag verschwindet auch von der Platte")
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

## The delivery path, end to end and over real HTTP: the idea must reach the disk
## before the attempt, stay there when the attempt fails, and leave the queue only
## once Telegram confirmed it.
##
## The relay points at a local server rather than at Telegram, and the server
## answers 500 first. So this suite proves the failure *and* the recovery without a
## network, and it reads the request the relay really built — the credentials, the
## chat id, the text — instead of trusting a stub. It used to swap
## `Telegram.send_item` for a lambda, which GDScript silently refused (see
## `api_url`), and so the assertions after it measured the real bot call.
##
## The server address is set to a closed port throughout, on purpose. That is the
## arrangement this bug lived in: an address that does not answer must no longer
## have any say in where a suggestion goes.
func _delivery() -> void:
	t.suite("Vorschlags-Warteschlange — Zustellung")
	var api: Node = tree.root.get_node_or_null("/root/Api")
	var game: Node = tree.root.get_node_or_null("/root/Game")
	var relay: Node = tree.root.get_node_or_null("/root/Telegram")
	if api == null or game == null or relay == null:
		t.fail("Die Autoloads Api, Game und Telegram fehlen")
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
	# `Api` writes nothing to disk in a `--script` run, exactly like `Loc` and
	# `Game` — the guard exists so a headless suite cannot rewrite the player's
	# real save. This suite is about the other half of that promise: that an idea
	# really does reach the disk before the attempt, so persistence has to be on
	# for the duration, and off again at the end.
	api._persist = true

	var baked_token := str(relay._token)
	var baked_chat := str(relay._chat_id)
	var baked_url := str(relay.api_url)
	var telegram := FakeTelegram.new()
	tree.root.add_child(telegram)
	relay._token = "123:ABC"
	relay._chat_id = "42"
	relay.api_url = telegram.url()
	telegram.reply_status = 500

	# Nothing about this depends on the address, and there is one, pointing at
	# nothing: the arrangement that used to swallow the suggestion.
	game.set_server_url("http://127.0.0.1:%d" % _closed_port())

	# 1. Telegram refuses. The idea must be queued, on disk, and reported as
	#    waiting — never as lost.
	var view: Dictionary = await api.submit_suggestion("Boss mit zwei Leben", "Test")
	t.check(view.is_empty(), "Ein abgelehnter Sendeversuch liefert keine Ansicht zurück")
	t.equal(api.pending_count(), 1, "Der Vorschlag bleibt in der Warteschlange")
	t.equal(api.pending_hint(), "1 Vorschlag wartet auf Netz", "Der Spieler sieht, dass es wartet")
	t.equal(pending_events.size(), 1, "Der Wartestand wird genau einmal gemeldet")
	t.check(failed_events.size() == 1 and str(failed_events[0]) == Loc.t("ui.queue_saved_telegram_failed"),
		"Die Meldung sagt 'nicht zugestellt' und nicht 'Server unerreichbar'")
	t.equal(sent_events.size(), 0, "Ohne Bestätigung wird kein Erfolg gemeldt")
	t.check(telegram.has_path("/bot123:ABC/sendMessage"), "Der Bot wurde genau einmal gefragt")
	var posts := telegram.with_path("/bot123:ABC/sendMessage")
	t.equal(posts.size(), 1, "Und genau einmal geantwortet ist nicht nötig")
	if posts.size() == 1:
		var body: Dictionary = posts[0]
		t.equal(str(body.get("chat_id", "")), "42", "Die Nachricht trägt die eingebackene Chat-ID")
		t.check(str(body.get("text", "")).contains("Boss mit zwei Leben"), "Und den Text des Spielers")
		t.equal(bool(body.get("disable_web_page_preview", false)), true,
			"Eine URL im Text darf keine Vorschau werden")

	# It was on the disk before the attempt, not after: an app kill in between
	# costs a retry, not the idea.
	var key := str(api._queue[0].get("clientKey", ""))
	var stored: Variant = JSON.parse_string(FileAccess.get_file_as_string(str(QueueClass.PATH)))
	var stored_items: Variant = (stored as Dictionary).get("items", []) if stored is Dictionary else []
	t.equal((stored_items as Array).size(), 1, "Die Idee stand auf der Platte, als der Versuch scheiterte")
	t.equal(str(((stored_items as Array)[0] as Dictionary).get("clientKey", "")), key, "…mit demselben clientKey")

	# 2. The network comes back. `wake()` is the path the app-resume
	#    notification takes — no restart involved.
	telegram.reply_status = 200
	failed_events.clear()
	api.wake()
	var delivered := await _wait_until(func() -> bool: return api.pending_count() == 0, 8.0)
	t.check(delivered, "Nach dem Aufwachen ist die Warteschlange leer")
	t.equal(api.pending_hint(), "", "Ohne Warteschlange verschwindet die Anzeige wieder")
	# `with_path()` builds a new array on every call, so this has to ask again —
	# the copy taken before the retry still holds one request.
	t.equal(posts.size(), 1, "Der Wiederholungsversuch ging an denselben Bot")
	t.equal(failed_events.size(), 0, "Der erfolgreiche Versuch meldet nichts als Fehler")
	t.equal(sent_events.size(), 1, "suggestion_sent feuert genau einmal")
	# No suggestion number exists: the backend never saw this idea.
	t.equal(sent_events[0][0], 0, "…und die Id ist 0, weil es keine gibt")
	t.equal(sent_events[0][1], 1, "…die Clustergröße likewise 1")

	api.suggestion_sent.disconnect(on_sent)
	api.suggestion_failed.disconnect(on_failed)
	api.pending_changed.disconnect(on_pending)
	api._persist = false
	relay._token = baked_token
	relay._chat_id = baked_chat
	relay.api_url = baked_url
	telegram.queue_free()
	game.set_server_url("")
	api._queue.clear()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(QueueClass.PATH))
	t.suite_done()


## The no-server case is the *normal* state on a player's device, and it used to
## be answered with "Offline" — a claim about a network nobody tried. The idea has
## to reach the owner anyway, and the bot is the route. What matters here is which
## message the player gets and where the idea ends up, because that pair is the
## whole difference between "lost" and "sent".
##
## Over real HTTP again, for the reason `api_url` gives: replacing `send_item` was
## refused by GDScript, so the old version of this suite was measuring the live bot
## while claiming to measure a stub.
func _telegram_route() -> void:
	t.suite("Vorschlags-Warteschlange — Zustellung an den Bot")
	var api: Node = tree.root.get_node_or_null("/root/Api")
	var game: Node = tree.root.get_node_or_null("/root/Game")
	var relay: Node = tree.root.get_node_or_null("/root/Telegram")
	if api == null or game == null or relay == null:
		t.fail("Die Autoloads Api, Game und Telegram fehlen")
		t.suite_done()
		return

	var failed_events: Array = []
	var on_failed := func(reason: String) -> void: failed_events.append(reason)
	api.suggestion_failed.connect(on_failed)
	api._queue.clear()
	api._persist = false
	game.set_server_url("")

	# The credentials are forced empty rather than assumed: a build made with
	# `npm run telegram:bake` carries real ones, a plain checkout does not, and a
	# suite that passed only on one of the two would be measuring the build
	# rather than the behaviour. The originals are kept so the end restores them.
	var baked_token := str(relay._token)
	var baked_chat := str(relay._chat_id)
	var baked_url := str(relay.api_url)
	var telegram := FakeTelegram.new()
	tree.root.add_child(telegram)
	relay.api_url = telegram.url()
	relay._token = ""
	relay._chat_id = ""

	# 1. This build carries no bot credentials. Nothing can be sent, and the
	#    player must be told *that* — not that the network is down. Nothing is
	#    asked of the server, so it must not even be reachable.
	t.check(not relay.is_configured(),
		"Ohne eingebackene Zugangsdaten ist der Bot nicht konfiguriert")
	var view: Dictionary = await api.submit_suggestion("Boss mit zwei Leben", "Test")
	t.check(view.is_empty(), "Ohne Weg nach draußen gibt es keine Ansicht")
	t.equal(api.pending_count(), 1, "Der Vorschlag bleibt in der Warteschlange")
	t.equal(telegram.seen.size(), 0, "Der Bot wurde gar nicht gefragt")
	t.check(failed_events.size() == 1 and str(failed_events[0]) == Loc.t("ui.queue_saved_no_route"),
		"Die Meldung nennt die fehlenden Zugangsdaten statt 'offline'")

	# 2. With credentials, the send is attempted and its failure is reported as a
	#    failure to deliver — never as a lost suggestion. The address is still
	#    empty, so this is the path a player with no server configured takes.
	relay._token = "123:ABC"
	relay._chat_id = "42"
	t.check(relay.is_configured(), "Mit Token und Chat-ID ist der Bot konfiguriert")
	telegram.reply_status = 500
	failed_events.clear()
	var second: Dictionary = await api.submit_suggestion("Noch eine Idee", "Test")
	t.check(second.is_empty(), "Ein gescheiterter Sendeversuch liefert keine Ansicht")
	t.equal(telegram.with_path("/bot123:ABC/sendMessage").size(), 1, "Der Bot wurde genau einmal gefragt")
	t.equal(api.pending_count(), 2, "Beide Ideen warten weiter")
	t.check(failed_events.size() == 1 and str(failed_events[0]) == Loc.t("ui.queue_saved_telegram_failed"),
		"Die Meldung sagt 'nicht zugestellt' und nicht 'Server unerreichbar'")

	# 3. A confirmed send removes the idea and returns a view that carries no
	#    suggestion number — the backend never saw it, and the dialog must not
	#    print an id it does not have.
	telegram.reply_status = 200
	failed_events.clear()
	var third: Dictionary = await api.submit_suggestion("Dritte Idee", "Test")
	t.check(not third.is_empty(), "Ein bestätigter Sendeversuch liefert eine Ansicht")
	t.equal(str(third.get("via", "")), "telegram", "Die Ansicht nennt den Weg über den Bot")
	t.check(not third.has("id") or int(third.get("id", 0)) == 0,
		"Ohne Backend gibt es keine Vorschlagsnummer zu zeigen")
	t.equal(api.pending_count(), 2, "Nur die zugestellte Idee hat die Warteschlange verlassen")
	t.equal(failed_events.size(), 0, "Der erfolgreiche Versuch meldet nichts als Fehler")

	# 4. The queued ideas drain through the retry timer, which is what stops a
	#    suggestion from sitting in `user://` forever.
	api._attempt = 3
	api._on_timer()
	var drained := await _wait_until(func() -> bool: return api.pending_count() == 0, 8.0)
	t.check(drained, "Die Warteschlange leert sich auch ohne Server über den Bot")
	t.equal(api.pending_hint(), "", "Ohne Warteschlange verschwindet die Anzeige")

	# Restore whatever the build actually carries, so this suite leaves no trace
	# on the following ones.
	relay._token = baked_token
	relay._chat_id = baked_chat
	relay.api_url = baked_url
	telegram.queue_free()
	api.suggestion_failed.disconnect(on_failed)
	api._attempt = 0
	api._arm(0)
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


## A one-route HTTP server on localhost: answers with `reply_status` and `reply`,
## and remembers what it was asked.
##
## It stands in for the bot's API. It used to stand in for the backend's
## `POST /api/suggestions`, which the game no longer calls — so it is not a
## leftover from that, it is the only way to see the request the relay really
## builds. `reply_status` is writable, so a case can fail a send and then let it
## succeed without a second server.
class FakeTelegram extends Node:
	var port: int = 0
	var seen: Array = []
	## Status every reply carries. 200 delivers, 500 is Telegram refusing.
	var reply_status := 200
	## `{"result": {"message_id": 99}}` is what a real answer looks like.
	var reply := {"ok": true, "result": {"message_id": 99}}

	var _tcp := TCPServer.new()
	var _conn: StreamPeerTCP = null
	var _bytes := PackedByteArray()
	var _answered := false

	func _init() -> void:
		if _tcp.listen(0, "127.0.0.1") == OK:
			port = _tcp.get_local_port()

	func url() -> String:
		return "http://127.0.0.1:%d" % port

	## The parsed bodies of all requests that went to `path`.
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
			_bytes = PackedByteArray()
			_answered = false
		if _conn == null:
			return
		# `put_data` only buffers, and the buffer is flushed by `poll()`. Letting go
		# of the connection in the same frame threw the answer away before it left —
		# the client then saw a status line with an empty body, and the code under
		# test reported "no answer" for a request that had been answered.
		#
		# `take_connection()` hands back a peer that is still `STATUS_CONNECTING`:
		# the handshake needs a few `poll()` calls first. Dropping it for that is
		# how the server ended up with `seen == []` and the client with a response
		# code of 0 — a connection refused that never happened. Only a closed or
		# failed peer is released; a connecting one is waited for.
		_conn.poll()
		var status := _conn.get_status()
		if status == StreamPeerTCP.STATUS_NONE or status == StreamPeerTCP.STATUS_ERROR:
			_conn = null
			return
		if status != StreamPeerTCP.STATUS_CONNECTED:
			return
		if _answered:
			return
		if _conn.get_available_bytes() <= 0:
			return
		var chunk: Array = _conn.get_data(_conn.get_available_bytes())
		_bytes.append_array(chunk[1])
		# `Content-Length` counts **bytes**, and the relay's body carries an em dash
		# in its author line: two characters short of what a String length reports.
		# Measuring the body in characters made this server wait for two bytes that
		# would never arrive, answer nothing, and leave the code under test looking
		# like it had never sent — which is exactly what happened before.
		var head_text := _bytes.get_string_from_utf8()
		var split := head_text.find("\r\n\r\n")
		if split < 0:
			return
		var expected := 0
		for line in head_text.substr(0, split).split("\r\n"):
			if line.begins_with("Content-Length:"):
				expected = int(line.get_slice(":", 1).strip_edges())
		# The separator is four ASCII bytes, so the byte offset is the same number.
		var body_bytes := _bytes.slice(split + 4)
		if body_bytes.size() < expected:
			return
		var request_line := head_text.substr(0, split).split(" ")
		seen.append({
			"path": str(request_line[1]) if request_line.size() > 1 else "",
			"body": JSON.parse_string(body_bytes.get_string_from_utf8()),
		})
		var payload := JSON.stringify(reply)
		var reason := "OK" if reply_status == 200 else "Internal Server Error"
		var head := "HTTP/1.1 %d %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % [reply_status, reason, payload.length()]
		_conn.put_data(head.to_utf8_buffer())
		_conn.put_data(payload.to_utf8_buffer())
		_answered = true


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


# --- Themed editions --------------------------------------------------------

## Three lobby tiles for one screen is a lobby that sells one game three times.
## The picker is the other half of folding them into one tile: the screen offers
## the editions itself. This suite pins both halves of that contract — which
## entries count as editions, and that a screen with them gets a working button
## and a dialog listing all of them.
##
## The dialog is also where the shared list kit is exercised (`Ui.scroll_list`,
## `Ui.list_row`): the cards used to be a bare `VBoxContainer` in a
## `CenterContainer`, and nothing clips either, so a family with more editions
## than the window holds pushed the head and the close button off the screen.
func _themed_editions() -> void:
	t.suite("Themenwahl")

	# The family is read, not declared: three registry entries that open one
	# screen script are three editions of one game. That is what makes the
	# folding safe — nothing has to be listed twice and kept in step.
	t.equal(ThemePickerClass.family_of("crystal3d").size(), 3,
		"Die drei Jumper-Fassungen sind eine Familie")
	t.equal(ThemePickerClass.family_of("tetris").size(), 1,
		"Tetris ist ein Spiel fuer sich")
	t.equal(ThemePickerClass.family_of("lobby").size(), 0,
		"Der Lobby gehoert gar keinem Spiel")

	# The current screen is not one of its own alternatives — that would give the
	# dialog a card for where the player already is.
	t.equal(ThemePickerClass.editions_for("crystal3d").size(), 2,
		"Das Kristall-Thema kennt die beiden anderen")
	t.check(ThemePickerClass.has_editions("crystal3d"),
		"Und genau die bekommt einen Knopf")
	t.check(not ThemePickerClass.has_editions("tetris"),
		"Ein Spiel ohne Fassungen behaelt seine Leiste")
	t.check(not ThemePickerClass.has_editions("lobby"),
		"Der Lobby auch nicht")

	# A card without a target is a picture: every edition has to name the screen
	# it opens, and none of them may be the one already open.
	var sound := true
	for edition in ThemePickerClass.editions_for("crystal3d_halloween"):
		var target := str(edition.get("screen", ""))
		sound = sound and target in ["crystal3d", "crystal3d_christmas"]
		sound = sound and not str(edition.get("name", "")).is_empty()
	t.check(sound, "Jede Fassung nennt ihr Ziel und ihren Namen")

	# Each edition keeps its own record, which is what the merge must not cost a
	# player: the three highscore keys stay with the three themes.
	var keys := 0
	for edition in ThemePickerClass.editions_for("crystal3d"):
		if not str(edition.get("highscore_key", "")).is_empty():
			keys += 1
	t.equal(keys, 2, "Jede Fassung fuehrt ihren eigenen Highscore")

	t.equal(str(ThemePickerClass.current_edition("crystal3d_halloween").get("screen", "")),
		"crystal3d_halloween", "Das Halloween-Thema erkennt sich selbst")
	t.check(ThemePickerClass.current_edition("lobby").is_empty(),
		"Der Lobby gehoert zu keinem Thema")

	# On a real screen: the top bar carries the button, and the dialog it opens
	# lists the other two editions plus the way back.
	var host := ScreenClass.new()
	host.screen_id = "crystal3d_christmas"
	tree.root.add_child(host)

	# One button, not three: it wears the edition that is on screen, and the
	# dialog it opens is where the others are named. Three extra captions would
	# have cost more of a phone's top bar than the switch is worth.
	var captions := ""
	for node in host.find_children("*", "Button", true, false):
		captions += str((node as Button).text)
	t.check("✧" in captions, "Die Leiste traegt das Zeichen der offenen Fassung")
	t.check("☠" not in captions, "Die anderen beiden stehen im Dialog, nicht in der Leiste")

	var layer := ThemePickerClass.open(host)
	t.check(layer != null, "Der Dialog baut sich ueber den Bildschirm")
	t.check(host.has_modal(), "Er liegt auf der Modal-Ebene des Bildschirms")
	t.check(ThemePickerClass.is_open(), "und weiss, dass er offen ist")
	t.equal(_cards_in(layer), 2, "Eine Karte je anderer Fassung")
	t.check(ThemePickerClass.open(host) == layer, "Ein zweiter Tap stapelt keinen zweiten Dialog")

	await _lists_stay_inside_their_box(layer)

	ThemePickerClass.close()
	# `queue_free()` frees at the end of the frame, so the layer is still a child
	# for the rest of this one. Reading `has_modal()` immediately would prove
	# nothing about whether it ever goes away.
	await tree.process_frame
	t.check(not host.has_modal(), "Schliessen nimmt die Ebene mit")
	t.check(not ThemePickerClass.is_open(), "und der Dialog weiss es")

	host.screen_id = "tetris"
	t.check(ThemePickerClass.open(host) == null, "Ein Spiel ohne Fassungen baut keinen Dialog")
	t.check(not host.has_modal(), "und legt auch keine Ebene an")
	host.queue_free()
	t.suite_done()


## Counts the edition cards below `node`. Marked with a meta rather than counted
## by type, because the dialog also holds the panel the cards sit in.
func _cards_in(node: Node) -> int:
	var found := 0
	var stack: Array[Node] = [node]
	while not stack.is_empty():
		var current: Node = stack.pop_back()
		if current.has_meta(ThemePickerClass.CARD_META):
			found += 1
		for child in current.get_children():
			stack.append(child)
	return found


## The first node of `kind` below `node`, or `null`. Asked for by type rather
## than indexed, so a tree that lost its node reports one failed check instead
## of a null dereference in the middle of a suite.
func _first_of(node: Node, kind: String) -> Node:
	var found := node.find_children("*", kind, true, false)
	return found[0] if found.size() > 0 else null


## A list of rows inside a box of a fixed height: the fit has to be a scroll, and
## not a row too thin to hit. A player filed this about the 3D lobby's game
## panel, which is a fixed 250 px tall while the "Puzzle" plaza lists six games —
## 142 px more than the panel has room for, and nothing clipped them, so the
## lower rows were painted over the bottom edge of the screen. The fix is the
## same here because the arithmetic and the widget are the game's, in `Ui`.
func _lists_stay_inside_their_box(layer: Control) -> void:
	# 1. The dialog's own cards sit in a list that clips, follows the focus and
	#    keeps a tap a tap.
	var list := _first_of(layer, "ScrollContainer") as ScrollContainer
	t.check(list != null, "Die Karten stehen in einer Liste, die rollt")
	if list != null:
		t.check(list.clip_contents,
			"und die Liste schneidet ab, statt ueber ihren Rand hinaus zu zeichnen")
		t.check(list.follow_focus,
			"sie holt einen fokussierten Eintrag von selbst in den Blick")
		t.check(list.scroll_deadzone == UiClass.LIST_SCROLL_DEADZONE,
			"ein Finger-Wackeln zaehlt als Tipp und nicht als Rollen")
		t.equal(_cards_in(UiClass.list_box(list)), 2, "und beide Fassungen stehen darin")
		t.check(list.custom_minimum_size.y > 0.0,
			"die Liste behaelt eine Hoehe, statt auf null zusammenzufallen")

	# 2. The arithmetic. Two rows in the room the dialog has keep their full
	#    height; twelve do not get squeezed to fit, because a row below
	#    `LIST_ROW_MIN` is no longer something a finger can hit and the answer to
	#    "one too many" has to be a scroll.
	var gap := float(ThemePickerClass.CARD_GAP)
	var full := ThemePickerClass.CARD_SIZE.y
	t.equal(UiClass.list_row(588.0, 2, gap, full), full, "Zwei Zeilen behalten ihre volle Hoehe")
	t.equal(UiClass.list_row(588.0, 12, gap, full), UiClass.LIST_ROW_MIN,
		"Zwelve Zeilen werden nicht duenngedrueckt")
	t.equal(UiClass.list_height(2, 78.0, 10.0), 166.0, "Die Hoehe einer Liste zaehlt die Abstaende mit")
	t.equal(UiClass.list_height(0, 78.0, 10.0), 0.0, "Eine leere Liste braucht keine Hoehe")
	t.equal(UiClass.list_row(588.0, 0, gap, full), full, "Ohne Zeile wird nichts verkleinert")
	# A screen whose own rows are already thinner than the touch minimum keeps
	# them: raising 40 to 44 would make the list taller than the screen asked
	# for and still not fit.
	t.equal(UiClass.list_row(135.0, 6, 6.0, 40.0), 40.0,
		"Ein eigener schmalerer Wert geht der Mindesthoehe vor")

	# 3. The failure itself, measured rather than argued: a box of a fixed height
	#    with far more rows than fit, and the list that keeps them inside it.
	var probe := UiClass.scroll_list(6)
	# What `Screen` and `WorldScreen` put on the screen, so the bar below is the
	# one a player sees and not Godot's default theme.
	probe.theme = UiThemeClass.shared()
	var rows := UiClass.list_box(probe)
	for i in 12:
		rows.add_child(UiClass.button("Spiel %d" % i, Vector2(0, 60)))
	probe.size = Vector2(320, 140)
	tree.root.add_child(probe)
	# `update_scrollbars()` runs deferred, and the page/max it needs are measured
	# in the same pass, so one frame is not enough to read them.
	await tree.process_frame
	await tree.process_frame
	t.check(probe.size.y <= 140.0, "Die Liste waechst nicht ueber ihre Box hinaus")
	t.check(rows.get_combined_minimum_size().y > probe.size.y,
		"der Inhalt ist groesser als der sichtbare Ausschnitt")
	t.check(probe.get_v_scroll_bar().max_value > 0.0, "und die Liste kann ihn rollen")
	t.check(probe.get_v_scroll_bar().get_minimum_size().x <= UiThemeClass.SCROLL_BAR_WIDTH,
		"Die Rollleiste ist schmal und traegt keine Pfeile")
	probe.queue_free()
	await tree.process_frame

	# 4. Where the slenderness comes from, without a layout: a vertical bar takes
	#    its width from `MAX(increment_icon.width, track content margins)`, so
	#    both halves are set. `Theme` cannot remove an icon, so the arrow is
	#    replaced by a 1x1 image rather than by `null`.
	var track := UiThemeClass.shared().get_stylebox("scroll", "VScrollBar")
	t.check(track is StyleBoxFlat, "Die Rollleiste des Spiels hat einen eigenen Kasten")
	if track is StyleBoxFlat:
		t.equal((track as StyleBoxFlat).get_minimum_size().x, UiThemeClass.SCROLL_BAR_WIDTH,
			"und der Kasten ist so schmal, wie er soll")
	var arrow := UiThemeClass.shared().get_icon("increment", "VScrollBar")
	t.check(arrow != null and arrow.get_width() <= UiThemeClass.SCROLL_BAR_WIDTH,
		"Der Pfeil des Bildschirms ist durch ein 1x1-Bild ersetzt")


# --- Server address ---------------------------------------------------------

## The dialog through which the backend address is entered. It used to live fixed
## in the arena game's menu, so it was unreachable from every other screen: an
## idea submitted from the main screen without an address sat in `user://` looking
## saved and never arrived. This suite secures both halves — that the address is
## reachable from everywhere, and that it wakes a waiting queue immediately.
func _server_address() -> void:
	t.suite("Server-Adresse")

	# The offline case has to be arranged, not assumed. An earlier suite in this
	# file points the autoload at a real port and clears it again at its end; if
	# that cleanup ever stops happening — or a new suite is added before this one
	# and forgets — the first assertion below would be asserting the state it did
	# not set up.
	Game.set_server_url("")
	# "no address", not "offline": the button states what is missing. A player who
	# never configured a server was told for weeks that their network was down.
	t.equal(ServerDialogClass.label(), "Server: " + Loc.t("ui.server_offline"),
		"Ohne Adresse nennt der Knopf die fehlende Adresse statt 'offline'")

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
	t.equal(ServerDialogClass.label(), "Server: " + Loc.t("ui.server_offline"),
		"Eine leere Adresse stellt den Zustand 'keine Adresse' wieder her")
	t.suite_done()


# --- Touch: the second finger ------------------------------------------------

## Every finger has to reach the action button, and only the first one ever did.
##
## Godot emulates a mouse button for exactly one finger — the index of the first
## `InputEventScreenTouch` it sees, see `Input::_parse_input_event_impl` — and
## `Button` reads nothing else. So the moment the virtual stick holds the first
## finger, ◈ got a raw `InputEventScreenTouch` and nothing more, and pressing it
## did nothing at all: "Drachenflug: i cannot fire while steering". Measured on
## the dragon flight screen, the button received that bare touch while the stick
## was held, and a touch *and* a mouse button when it was alone.
func _second_finger() -> void:
	t.suite("Steuerung — zweiter Finger")

	var host := Control.new()
	host.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	host.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tree.root.add_child(host)

	# A Dictionary, not three Ints: a GDScript lambda captures a local *by
	# value*, so `func(): held += 1` would count inside the lambda and leave
	# this one at zero.
	var seen := {"held": 0, "up": 0, "pressed": 0}
	var button := TouchButtonClass.new()
	button.size = Vector2(66.0, 66.0)
	button.focus_mode = Control.FOCUS_NONE
	button.add_theme_stylebox_override("normal", UiThemeClass.flat(Color(0.098, 0.141, 0.239, 0.75), UiThemeClass.ACCENT, 20))
	button.add_theme_stylebox_override("pressed", UiThemeClass.flat(UiThemeClass.ACCENT.darkened(0.25), Color.WHITE, 20))
	host.add_child(button)
	button.button_down.connect(func() -> void: seen["held"] += 1)
	button.button_up.connect(func() -> void: seen["up"] += 1)
	button.pressed.connect(func() -> void: seen["pressed"] += 1)

	var idle := button.get_theme_stylebox("normal")
	var down_look := button.get_theme_stylebox("pressed")

	# Finger 0 belongs to the stick throughout and never arrives here — the
	# viewport routes it there — so the button is pressed with finger 1, which is
	# the tablet, and now the thing that has to work.
	button._gui_input(_touch(1, true, Vector2(33.0, 33.0)))
	t.equal(int(seen["held"]), 1, "Der zweite Finger drueckt den Knopf, waehrend der Stick laeuft")
	t.check(button.get_theme_stylebox("normal") == down_look,
		"Der gehaltene Knopf sieht aus wie gedrueckt")

	# The finger coming up again fires it, which is what horse runner's ◀ and ▶
	# rely on for a single tap.
	button._gui_input(_touch(1, false, Vector2(33.0, 33.0)))
	t.equal(int(seen["pressed"]), 1, "Und das Loslassen loest ihn aus")
	t.equal(int(seen["up"]), 1, "Der Knopf meldet das Ende des Druckes")
	t.check(button.get_theme_stylebox("normal") == idle,
		"Danach sieht er wieder ungedrueckt aus")

	# A finger that slides off before lifting is a cancelled tap, not a press —
	# the same as a `Button` released outside its own rect.
	button._gui_input(_touch(2, true, Vector2(33.0, 33.0)))
	button._gui_input(_drag(2, Vector2(300.0, 300.0)))
	button._gui_input(_touch(2, false, Vector2(300.0, 300.0)))
	t.equal(int(seen["pressed"]), 1, "Ein Finger, der wegrutscht, drueckt nicht")

	# A second finger on a button that is already held must not take it over:
	# the player may be sliding a thumb off it, or resting a second one on it.
	button._gui_input(_touch(2, true, Vector2(33.0, 33.0)))
	button._gui_input(_touch(3, true, Vector2(10.0, 10.0)))
	button._gui_input(_touch(3, false, Vector2(10.0, 10.0)))
	t.equal(int(seen["held"]), 3, "Der zweite Finger nimmt den Knopf nicht dem ersten weg")
	t.equal(int(seen["pressed"]), 1, "Und loest keinen weiteren Tipp aus")
	button._gui_input(_touch(2, false, Vector2(33.0, 33.0)))
	t.equal(int(seen["pressed"]), 2, "Erst der Finger, der den Knopf haelt, zaehlt")
	t.equal(int(seen["up"]), 3, "Jeder haelt nur seinen eigenen Druck")

	# The emulated mouse event for the same click must not press a second time:
	# `emulate_touch_from_mouse` sends the touch event first, and horse runner's
	# ◀ would otherwise shift two lanes per tap.
	var mouse := InputEventMouseButton.new()
	mouse.button_index = MOUSE_BUTTON_LEFT
	mouse.pressed = true
	mouse.device = InputEvent.DEVICE_ID_EMULATION
	mouse.position = Vector2(33.0, 33.0)
	button._gui_input(mouse)
	t.equal(int(seen["held"]), 3, "Die nachgeahmte Maus zaehlt nicht noch einmal")

	# A disabled button stays dead for every finger.
	button.disabled = true
	button._gui_input(_touch(4, true, Vector2(33.0, 33.0)))
	button._gui_input(_touch(4, false, Vector2(33.0, 33.0)))
	t.equal(int(seen["held"]), 3, "Ein gesperrter Knopf antwortet keinem Finger")
	t.equal(int(seen["pressed"]), 2, "und loest auch nichts aus")
	button.disabled = false

	# It has to stay a `Button` for the callers: the dragon RPG holds its dash
	# button in a `var _dash_button: Button` and only moves and dims it.
	t.check(button is Button, "Der Knopf bleibt ein Button fuer seine Aufrufer")

	host.queue_free()
	t.suite_done()


## A fire that lights nothing is a cone.
##
## "Mesh-Galerie · Campfire: has to be more beautiful" was written standing in
## front of that pedestal, and both causes are in core code rather than in the
## mesh. The gallery tints every mesh to its standard colour, and
## `material_override` threw away all three surfaces the Blender script builds —
## measured on the imported `rpg/campfire`: brown logs, an orange flame and a
## gold core, the last two with an emission around 2.5. After the tint: one flat
## `f97316`, nothing glowing. And a mesh that is only geometry gives off no
## light at all, which is the one thing a campfire exists to do.
func _fire() -> void:
	t.suite("Feuer — Licht und Glut")

	# The gallery asks for a detail level by path and everybody else asks by
	# key, so the funnel has to know which of the two it was handed.
	t.equal(str(FireGlowClass.mesh_key("rpg/campfire")), "rpg/campfire", "Ein Schluessel bleibt sich selbst")
	t.equal(str(FireGlowClass.mesh_key("res://assets/meshes/rpg/campfire.glb")), "rpg/campfire", "Und ein Low-Pfad auch")
	t.equal(str(FireGlowClass.mesh_key("res://assets/meshes/med/rpg/campfire.glb")), "rpg/campfire", "Wie eine Detailstufe als Pfad")
	t.equal(str(FireGlowClass.mesh_key("candy/lolly")), "candy/lolly", "Ein Bonbon wird nicht versehentlich zum Lagerfeuer")

	t.check(bool(FireGlowClass.burns("rpg/campfire")), "Das Lagerfeuer brennt")
	t.check(not bool(FireGlowClass.burns("candy/lolly")), "Ein Bonbon nicht")

	# The funnel itself: loaded through the one function every 3D screen uses.
	var campfire: Node3D = WorldScreenClass.mesh("rpg/campfire", AssetRegistry.color_of("rpg/campfire"))
	t.check(campfire != null, "Das Lagerfeuer laesst sich laden")
	t.check(_fire_glow_of(campfire) != null, "Und bringt sein eigenes Feuer mit")
	# The material override is what flattened it: the gallery's colour sits on
	# every surface of the mesh, so an empty list is the wood and the flame again.
	t.check(_material_overrides(campfire).is_empty(), "Es traegt nicht mehr die Farbe des Sockels ueber sich")
	var lolly: Node3D = WorldScreenClass.mesh("candy/lolly", AssetRegistry.color_of("candy/lolly"))
	t.check(_fire_glow_of(lolly) == null, "Ein Bonbon bekommt kein Feuer")
	t.check(not _material_overrides(lolly).is_empty(), "Und behaelt seine Farbe des Sockels")

	# The same, one detail level down: the gallery's default is the low tier, but
	# the tiers are paths, and a fire that only burns on one of them is a bug.
	var hall: Node3D = WorldScreenClass.mesh("res://assets/meshes/med/rpg/campfire.glb", AssetRegistry.color_of("rpg/campfire"))
	t.check(_fire_glow_of(hall) != null, "Auch die mittlere Detailstufe brennt")

	var host := Node3D.new()
	tree.root.add_child(host)
	var glow: FireGlow = FireGlowClass.attach(host, "rpg/campfire")
	t.check(glow != null, "Ein Feuer haengt sich an einen Knoten")
	t.check(FireGlowClass.attach(host, "candy/lolly") == null, "An ein Bonbon haengt sich keines")

	var light: OmniLight3D = null
	var embers: CPUParticles3D = null
	var pool: Sprite3D = null
	for child in glow.get_children():
		if child is OmniLight3D:
			light = child
		elif child is CPUParticles3D:
			embers = child
		elif child is Sprite3D:
			pool = child
	t.check(light != null, "Es wirft Licht")
	t.check(embers != null, "Und laesst Funken steigen")
	t.check(pool != null, "Und legt einen Schein auf den Boden")
	t.check(light != null and not light.shadow_enabled,
		"Der Schein wirft keinen Schatten — der Compatibility-Renderer kann das nicht")
	t.check(embers != null and int(embers.amount) == int(FireGlowClass.EMBER_COUNT),
		"So viele Funken, wie festgelegt")
	t.check(embers != null and not bool(embers.local_coords),
		"Die Funken steigen gerade, auch wenn sich der Sockel dreht")

	# Four seconds of flicker: the fire never goes out, never burns brighter than
	# its base value, and never sits still.
	var low := INF
	var high := -INF
	for i in 240:
		glow._process(1.0 / 60.0)
		low = minf(low, light.light_energy)
		high = maxf(high, light.light_energy)
	t.check(low > 0.0, "Das Feuer geht nie aus")
	t.check(high <= float(FireGlowClass.LIGHT_ENERGY) + 0.001, "Und brennt nie heller als seine Grundstufe")
	t.check(high - low > 0.5, "Aber es flackert")

	host.queue_free()
	t.suite_done()


## The fire on a loaded mesh, or `null` when it does not burn.
func _fire_glow_of(node: Node) -> FireGlow:
	for child in node.get_children():
		if child is FireGlow:
			return child
	return null


## Every `material_override` in the subtree: what `tint()` puts on a mesh.
func _material_overrides(node: Node) -> Array[StandardMaterial3D]:
	var out: Array[StandardMaterial3D] = []
	var stack: Array[Node] = [node]
	while not stack.is_empty():
		var current: Node = stack.pop_back()
		if current is MeshInstance3D and (current as MeshInstance3D).material_override != null:
			out.append((current as MeshInstance3D).material_override as StandardMaterial3D)
		for child in current.get_children():
			stack.append(child)
	return out


## A touch event on a finger, at `at` in the coordinates of whatever control
## receives it.
func _touch(index: int, pressed: bool, at: Vector2) -> InputEventScreenTouch:
	var event := InputEventScreenTouch.new()
	event.index = index
	event.pressed = pressed
	event.position = at
	return event


func _drag(index: int, at: Vector2) -> InputEventScreenDrag:
	var event := InputEventScreenDrag.new()
	event.index = index
	event.position = at
	return event
