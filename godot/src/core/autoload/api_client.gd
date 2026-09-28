extends Node
## Thin HTTP client for the Singular 80 backend.
##
## Every call is fire-and-forget with a short timeout: on a phone the game must
## never block on a missing server. When `Game.server_url` is empty the calls
## resolve to an empty result and the callers fall back to bundled data.
##
## Suggestions are the one thing that is not allowed to be lost. A submitted
## idea goes into the persistent `SuggestionQueue` **before** any send is
## attempted, keeps the same `clientKey` across every retry, and leaves the queue
## only once the server confirmed it. Retries happen with a bounded backoff while
## items are pending and again whenever the app comes back to the foreground —
## which is exactly when a phone regains connectivity.

signal suggestion_sent(id: int, cluster_size: int)
signal suggestion_failed(reason: String)
## Emitted whenever the number of queued suggestions changes, so a screen can
## show the pending hint.
signal pending_changed(count: int)

const TIMEOUT := 4.0
const QueueClass := preload("res://src/core/logic/suggestion_queue.gd")

var online: bool = false
var _queue: Array[Dictionary] = []
var _timer: Timer
var _attempt: int = 0
var _busy: bool = false
var _announced: int = 0


func _ready() -> void:
	process_priority = -40
	# The content of `user://` is the whole point: the list can have been
	# sitting there since the last start, a reboot or a crash.
	_queue = QueueClass.restore()
	_timer = Timer.new()
	_timer.one_shot = true
	_timer.timeout.connect(_on_timer)
	add_child(_timer)
	_announce_pending()
	if not _queue.is_empty():
		# Startup catches up with the list quickly. Without a configured server
		# there is nothing to probe, and the first contact (or a resume) takes
		# over.
		_arm(0, 0.25 if Game.has_server() else 60.0)


func _notification(what: int) -> void:
	# Waking the phone is the moment the network comes back. Godot reports it
	# as window focus (Android calls `OS_Android::main_loop_focusin`, which
	# reaches every child as `WINDOW_EVENT_FOCUS_IN`) and, depending on the
	# platform, additionally as application focus or resume.
	if what == NOTIFICATION_WM_WINDOW_FOCUS_IN \
			or what == NOTIFICATION_APPLICATION_FOCUS_IN \
			or what == NOTIFICATION_APPLICATION_RESUMED:
		wake()


## Resets the backoff and retries at once. After the phone wakes up this is
## the honest reaction: the network has only just come back.
func wake() -> void:
	if _queue.is_empty():
		return
	_arm(0, 0.25)


## True when a server URL is configured and its health endpoint answered.
func probe() -> bool:
	if not Game.has_server():
		online = false
		return false
	var result: Variant = await _request("/api/health")
	online = result is Dictionary
	return online


# --- content ----------------------------------------------------------------

## Fetches the live content pack, or `null` when unavailable.
func get_content() -> Variant:
	if not Game.has_server():
		return null
	return await _request("/api/content")


# --- suggestions ------------------------------------------------------------

## Submits a player suggestion. Returns the parsed view, or `{}` when the
## backend did not take it **yet** — the suggestion is then queued in `user://`
## and delivered on a later attempt, with the same `clientKey`, so a lost
## response cannot turn into a duplicate.
## `context` names the screen or area the idea came from; it is prepended to the
## text so the dashboard can group ideas without the author having to say it.
func submit_suggestion(text: String, author: String, context: String = "") -> Dictionary:
	# 1. Queue it and write it to disk **before** sending. From here on the
	#    idea survives a crash, an exit and a reboot.
	var item := QueueClass.make_item(SuggestionContext.compose(context, text), author, "game")
	var dropped := QueueClass.push(_queue, item)
	_save()
	# `push()` appends the entry and may have corrected its key; what counts
	# is therefore the one from the list, not the one from `item`.
	var key := str((_queue[_queue.size() - 1] as Dictionary).get("clientKey", ""))
	if not dropped.is_empty():
		suggestion_failed.emit(QueueClass.cap_warning(dropped, QueueClass.MAX_ITEMS))
	_announce_pending()
	if not Game.has_server():
		suggestion_failed.emit(Loc.t("ui.queue_saved_offline"))
		_arm(0, 0.25)
		return {}
	if _busy:
		# A background flush is already running. The new entry is safe and
		# goes with its next pass or the next backoff.
		return {}
	# 2. Send once directly — the dialog waits for the result.
	_busy = true
	var view := await _deliver(key)
	_busy = false
	if view.is_empty():
		suggestion_failed.emit(Loc.t("ui.queue_saved_unreachable"))
		_arm(1)
		return {}
	_announce_pending()
	_arm(0)
	return view


## Reads the most recently implemented suggestions for the main-menu ticker.
func implemented_suggestions(limit: int = 8) -> Array:
	if not Game.has_server():
		return []
	var result: Variant = await _request("/api/suggestions?status=implemented")
	if not (result is Dictionary):
		return []
	var list: Variant = (result as Dictionary).get("suggestions", [])
	if not (list is Array):
		return []
	var out: Array = []
	for entry in (list as Array):
		if entry is Dictionary:
			out.append(entry)
		if out.size() >= limit:
			break
	return out


## How many suggestions are still waiting for the network.
func pending_count() -> int:
	return _queue.size()


## UI text for the pending count, empty when nothing is waiting.
func pending_hint() -> String:
	return QueueClass.pending_hint(pending_count())


## Sends everything that is still queued. Safe to call at any time: it is what
## the startup path and the resume path use. What does not go through stays in
## the queue and is retried with backoff.
func flush_queue() -> void:
	if _busy or _queue.is_empty():
		_arm(0)
		return
	if not Game.has_server():
		# Ohne eingetragenen Server gibt es nichts zu proben; `_arm` hält den
		# Versuch im Blick, falls die Adresse noch im laufenden Spiel gesetzt wird.
		_arm(_attempt)
		return
	_busy = true
	var failed := false
	# Über eine Kopie: `_deliver()` nimmt erfolgreiche Einträge aus `_queue`.
	for entry in _queue.duplicate():
		var view := await _deliver(str((entry as Dictionary).get("clientKey", "")))
		if view.is_empty():
			# Der erste Fehlschlag spricht für alle weiteren: weiterzumachen hieße,
			# die volle Timeout-Zeit N Mal zu warten.
			failed = true
			break
	_busy = false
	_announce_pending()
	if failed:
		_arm(_attempt + 1)
	else:
		_attempt = 0
		_arm(0)


## Sends one queued item. Returns the parsed view, or `{}` when the item stays in
## the queue. It is removed **only** after the server confirmed it: a lost
## response then costs a retry with the same `clientKey`, not the idea.
func _deliver(client_key: String) -> Dictionary:
	var item := QueueClass.find(_queue, client_key)
	if item.is_empty():
		return {}
	var body: Dictionary = QueueClass.request_body(item)
	var result: Variant = await _request("/api/suggestions", HTTPClient.METHOD_POST, body)
	if not (result is Dictionary):
		return {}
	var view: Dictionary = result
	QueueClass.remove(_queue, client_key)
	_save()
	suggestion_sent.emit(int(view.get("id", 0)), int(view.get("clusterSize", 1)))
	return view


# --- retry ------------------------------------------------------------------

func _on_timer() -> void:
	if _queue.is_empty():
		return
	if not Game.has_server():
		# Nichts zu proben, aber die Adresse kann noch im laufenden Spiel
		# gesetzt werden — der Backoff bleibt der Taktgeber.
		_arm(_attempt + 1)
		return
	_attempt_queue()


func _attempt_queue() -> void:
	if _busy or _queue.is_empty() or not Game.has_server():
		_arm(_attempt)
		return
	_busy = true
	# Erst der Gesundheits-Endpunkt: ein erzwungener POST genau dann, wenn das
	# Gerät kein Netz hat, ist das, was den Akteur leert. Der Probe kostet
	# dagegen fast nichts.
	var reachable: bool = await probe()
	_busy = false
	if not reachable:
		_arm(_attempt + 1)
		return
	flush_queue()


## Armiert den nächsten Zustellversuch. Ohne `wait` gilt die Backoff-Zeit der
## Stufe `attempt`; ein eigener Wert überschreibt sie (Start, Resume).
func _arm(attempt: int, wait: float = -1.0) -> void:
	_attempt = maxi(attempt, 0)
	if _queue.is_empty():
		if _timer != null:
			_timer.stop()
		return
	if _timer == null:
		return
	if wait < 0.0:
		wait = QueueClass.backoff_seconds(_attempt)
	# Nie 0 s: ein sofort neu gestarteter Timer liefe im selben Frame weiter und
	# die Warteschlange ab einer bestimmten Länge im Sekundentakt leer.
	_timer.wait_time = maxf(wait, 0.25)
	_timer.start()


func _announce_pending() -> void:
	var count := pending_count()
	if count == _announced:
		return
	_announced = count
	pending_changed.emit(count)


## Schreibt die Warteschlange auf die Platte. Aufrufer müssen das **vor** der
## Antwort des Servers tun: was hier steht, ist das, was ein Absturz überlebt.
func _save() -> void:
	QueueClass.persist(QueueClass.PATH, _queue)


# --- transport --------------------------------------------------------------

func _request(path: String, method: int = HTTPClient.METHOD_GET, body: Variant = null) -> Variant:
	var base := Game.server_url.strip_edges().trim_suffix("/")
	if base == "":
		return null
	var headers := PackedStringArray(["Content-Type: application/json", "Accept: application/json"])
	var request_body := "" if body == null else JSON.stringify(body)
	var http := HTTPRequest.new()
	http.timeout = TIMEOUT
	http.accept_gzip = true
	add_child(http)
	var err := http.request(base + path, headers, method, request_body)
	if err != OK:
		http.queue_free()
		return null
	var results: Array = await http.request_completed
	http.queue_free()
	if results.size() < 4:
		return null
	var code: int = int(results[1])
	var payload: PackedByteArray = results[3]
	if code < 200 or code >= 300:
		return null
	var text := payload.get_string_from_utf8()
	if text.strip_edges() == "":
		return {}
	var parsed: Variant = JSON.parse_string(text)
	return parsed
