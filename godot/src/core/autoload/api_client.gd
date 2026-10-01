extends Node
## Thin HTTP client for the Singular 80 backend, and the queue of suggestions
## waiting to be sent.
##
## Every call is fire-and-forget with a short timeout: on a phone the game must
## never block on a missing server.
##
## ## A suggestion goes to Telegram. There is no second route.
##
## The game used to post a suggestion to `POST /api/suggestions` whenever a
## server address was configured, and to the bot only when none was. That
## "whenever" was the bug: an address that is set but no longer answers — a typo,
## a machine that moved, `127.0.0.1` on a tablet that is not the server — makes
## the idea wait there forever, silently, while the one route that would have
## worked is never tried. Two routes meant the choice was made by a stale config
## file, not by what actually works. So the server path is gone: content and
## highscores still use the configured address, a suggestion never does.
##
## The address is irrelevant to `submit_suggestion()`, which is what a reader
## needs to see to know where a suggestion goes.

signal suggestion_sent(id: int, cluster_size: int)
signal suggestion_failed(reason: String)
## Emitted when the queued count changes, so a screen can show the pending hint.
signal pending_changed(count: int)

const TIMEOUT := 4.0
const QueueClass := preload("res://src/core/logic/suggestion_queue.gd")

## Whether the player's queue may be written. A `--script` run loads the
## autoloads for real, and `restore()` writes the repaired list straight back —
## so a green suite replaced the suggestions the player was still waiting to
## send. `Game.persist` is the same switch for the config file: off in a
## `--script` run, on in every real launch, and nothing in the game turns it off.
var _persist := not OS.get_cmdline_args().has("--script")

var _queue: Array[Dictionary] = []
var _timer: Timer
var _attempt: int = 0
var _busy: bool = false
var _announced: int = 0
## Health as of the last probe. Private, because a public `online` reads like
## "the network works" while it is one answer from one moment — and nothing
## outside this file ever asked for it.
var _reachable: bool = false


func _ready() -> void:
	process_priority = -40
	# Restored from `user://`: the list survives a crash or a reboot.
	_queue = QueueClass.restore(QueueClass.PATH, QueueClass.MAX_ITEMS, _persist)
	_timer = Timer.new()
	_timer.one_shot = true
	_timer.timeout.connect(_on_timer)
	add_child(_timer)
	_announce_pending()
	if not _queue.is_empty():
		# Startup catches up at once. The route is Telegram and nothing else, so
		# there is no address to wait for — the earlier "60 s without a server"
		# delay only postponed an idea that could have gone out immediately.
		_arm(0, 0.25)


func _notification(what: int) -> void:
	# Waking the phone is when the network comes back. Android reports that as
	# `APPLICATION_FOCUS_IN` and `APPLICATION_RESUMED`; the window notification is
	# the one the desktop and the editor deliver, and it is documented on `Node`,
	# not only on `Window`. Which of them a given platform actually sends was not
	# measured here — `wake()` is the cheap half of this, since it returns
	# without a request unless something is really waiting.
	if what == NOTIFICATION_WM_WINDOW_FOCUS_IN \
			or what == NOTIFICATION_APPLICATION_FOCUS_IN \
			or what == NOTIFICATION_APPLICATION_RESUMED:
		wake()


## Resets the backoff and retries at once: the network has only just come back.
## Every focus the window gets ends up here, and most of them have nothing to do
## with the network — the notification shade, the keyboard, a permission dialog,
## a phone call. So it only does something when something is waiting *and* the
## backoff is actually running.
func wake() -> void:
	if _queue.is_empty() or _attempt == 0:
		return
	_arm(0, 0.25)


## True when a server URL is configured and its health endpoint answered. The
## configured address is for content and highscores; a suggestion never goes
## there.
func probe() -> bool:
	if not Game.has_server():
		_reachable = false
		return false
	if not _try_lock():
		# A delivery owns the health request right now. Answer with the last known
		# state instead of "no" — the caller only uses this to decide whether a
		# further request is worth it, and "no" would skip content that is about
		# to arrive.
		return _reachable
	var answer: bool = await _probe_health()
	_unlock()
	return answer


## The health request itself, without the guard. Callers that already hold the
## mutex come here: through `probe()` they would only be told the state of the
## previous attempt.
func _probe_health() -> bool:
	var result: Variant = await _request("/api/health")
	_reachable = result is Dictionary
	return _reachable


## Sends one entry straight to the owner's Telegram bot. Returns the view, or `{}`
## when the idea stays queued.
##
## The view carries `via: "telegram"` and a `messageId` rather than a suggestion
## `id`, because the backend does not number it: a suggestion sent from the device
## lands in the chat and not in the dashboard. The dialog reads the flag instead
## of printing a number it does not have.
func _deliver_direct(client_key: String) -> Dictionary:
	if not Telegram.is_configured():
		# A build without credentials cannot deliver at all. Say that rather than
		# "offline" — the network may be perfectly fine.
		suggestion_failed.emit(Loc.t("ui.queue_saved_no_route"))
		return {}
	var item := QueueClass.find(_queue, client_key)
	if item.is_empty():
		return {}
	var result: Dictionary = await Telegram.send_item(item)
	if not bool(result.get("ok", false)):
		# Not "server unreachable" — no server was involved. The idea waits and
		# goes out on its own; saying so is what keeps a phone in a dead spot from
		# looking like a lost suggestion.
		suggestion_failed.emit(Loc.t("ui.queue_saved_telegram_failed"))
		_arm(1)
		return {}
	# Removed only after Telegram confirmed it: a lost answer costs a retry, never
	# the idea.
	QueueClass.remove(_queue, client_key)
	_save()
	_announce_pending()
	suggestion_sent.emit(0, 1)
	return {"id": 0, "clusterSize": 1, "via": "telegram", "messageId": int(result.get("messageId", 0))}


## Sends everything that is still queued, entry by entry. `false` when an attempt
## failed, so the caller arms the backoff.
##
## Over a copy: a delivered entry leaves `_queue` from inside `_deliver_direct()`.
func _flush_direct() -> bool:
	var failed := false
	for entry in _queue.duplicate():
		if (await _deliver_direct(str((entry as Dictionary).get("clientKey", "")))).is_empty():
			# The first failure speaks for all; continuing would wait out N timeouts.
			failed = true
			break
	return failed


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
## Submits a player suggestion. Returns the view, or `{}` when Telegram did not
## take it **yet** — the suggestion is then queued in `user://` and delivered on a
## later attempt, with the same `clientKey`, so a lost answer cannot turn into a
## duplicate.
## `context` names the screen or area the idea came from; it is prepended to the
## text so the chat message says where the idea belongs, without the author
## having to.
func submit_suggestion(text: String, author: String, context: String = "") -> Dictionary:
	# 1. Queue it and write it to disk **before** sending: from here on the idea
	#    survives a crash, an exit and a reboot.
	var item := QueueClass.make_item(SuggestionContext.compose(context, text), author, "game")
	var dropped := QueueClass.push(_queue, item)
	_save()
	# `push()` may correct the key, so read it back from the list, not from `item`.
	var key := str((_queue[_queue.size() - 1] as Dictionary).get("clientKey", ""))
	if not dropped.is_empty():
		suggestion_failed.emit(QueueClass.cap_warning(dropped, QueueClass.MAX_ITEMS))
	_announce_pending()
	if not _try_lock():
		# A flush is already running; the new entry goes out with its next pass.
		return {}
	# 2. Send once directly — the dialog waits for the result. `_deliver_direct()`
	#    reports its own failure, so a second message here would be wrong.
	var view := await _deliver_direct(key)
	_unlock()
	if view.is_empty():
		_arm(1)
		return {}
	_attempt = 0
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


## Sends everything that is still queued. What does not go through stays in the
## queue and is retried with backoff.
func flush_queue() -> void:
	if _queue.is_empty() or not _try_lock():
		_arm(0)
		return
	var failed := await _flush_direct()
	_unlock()
	_announce_pending()
	if failed:
		_arm(_attempt + 1)
	else:
		_attempt = 0
		_arm(0)


# --- retry ------------------------------------------------------------------

func _on_timer() -> void:
	if _queue.is_empty():
		return
	if not Telegram.is_configured():
		# No route at all: nothing to try. The credentials of a build can still
		# arrive under the player's hands, so keep the backoff running rather than
		# dropping the idea.
		_arm(_attempt + 1)
		return
	# There is no health endpoint to probe first — the route is the bot's
	# `sendMessage`, and that call decides on its own. The backoff absorbs a phone
	# without signal.
	flush_queue()


## The manual mutex the two request paths share — `probe` and `flush_queue`, with
## `submit_suggestion` as the third caller. A `Node` cannot hold a lock across an
## `await` any other way, and skipping it is not a slow path but a wrong one: two
## concurrent requests, and one of the callers walking away believing it had sent
## the queue.
func _try_lock() -> bool:
	if _busy:
		return false
	_busy = true
	return true


func _unlock() -> void:
	_busy = false


## Arms the next delivery attempt. Without `wait` the backoff time of level
## `attempt` applies; an explicit value overrides it (startup, resume).
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
	# Never 0 s: a timer restarted at once fires in the same frame.
	_timer.wait_time = maxf(wait, 0.25)
	_timer.start()


func _announce_pending() -> void:
	var count := pending_count()
	if count == _announced:
		return
	_announced = count
	pending_changed.emit(count)


## Writes the queue to disk; callers must do this **before** Telegram answers.
## A `--script` run leaves the player's own file alone — see `_persist`.
func _save() -> void:
	if not _persist:
		return
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
