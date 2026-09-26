extends Node
## Thin HTTP client for the Singular 80 backend.
##
## Every call is fire-and-forget with a short timeout: on a phone the game must
## never block on a missing server. When `Game.server_url` is empty (or the
## device is offline) the calls resolve to an empty result and the callers fall
## back to bundled data.

signal suggestion_sent(id: int, cluster_size: int)
signal suggestion_failed(reason: String)

const TIMEOUT := 4.0

var online: bool = false
var _queue: Array[Dictionary] = []


func _ready() -> void:
	process_priority = -40


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
## backend is unreachable (the suggestion is queued for the next attempt).
## `context` names the screen or area the idea came from; it is prepended to the
## text so the dashboard can group ideas without the author having to say it.
func submit_suggestion(text: String, author: String, context: String = "") -> Dictionary:
	var body := {"text": SuggestionContext.compose(context, text), "author": author, "source": "game"}
	if not Game.has_server():
		_queue.append(body)
		suggestion_failed.emit("Offline — Vorschlag lokal gespeichert.")
		return {}
	var result: Variant = await _request("/api/suggestions", HTTPClient.METHOD_POST, body)
	if result is Dictionary:
		var view: Dictionary = result
		suggestion_sent.emit(int(view.get("id", 0)), int(view.get("clusterSize", 1)))
		return view
	suggestion_failed.emit("Server nicht erreichbar — Vorschlag lokal gespeichert.")
	return {}


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


## Retries everything that failed while offline.
func flush_queue() -> void:
	if _queue.is_empty() or not Game.has_server():
		return
	var pending := _queue.duplicate()
	_queue.clear()
	for body in pending:
		submit_suggestion(str(body.get("text", "")), str(body.get("author", "Anonym")))


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
