extends Node
## Direct delivery of a player suggestion to the owner's Telegram bot.
##
## ## Why this exists
##
## The backend is the normal delivery path and it is the only one that can feed
## the dashboard and the agent runner. But it is a server on one machine, and a
## player has no reason to know its address. Without one the game used to answer
## "offline" — a statement about a network nobody tried — and kept the idea in
## `user://` where it stayed forever. That was the wrong message about the wrong
## thing: the address was missing, not the connection.
##
## So when no server is configured, this relay sends the suggestion straight to
## the bot from the device. The player needs internet and nothing else; there is
## no machine of the owner's involved.
##
## ## The token is in the build
##
## `scripts/bake-telegram.mjs` writes `res://telegram_config.gd` from `.env` at
## build time, and that generated file is git-ignored, so no token is committed
## to the public repository. It is nevertheless **extractable from every APK**:
## an APK is a zip and `apktool` is free. Anyone who unpacks the app can read
## the token and then use the bot as if they were this game — sending messages
## into the owner's chat, and reading anything the bot can see. Telegram offers
## no way to restrict a token by application signature or source address, so
## this cannot be fixed from the client side. The only real remedy is to rotate
## the token (`@BotFather` → `/revoke`) and move delivery behind a relay
## server. This is a deliberate, owner-approved trade, recorded here so nobody
## rediscovers it as a surprise.
##
## ## What is sent
##
## Plain text, without `parse_mode`. The server escapes HTML before sending
## player text; doing that twice, on two platforms, is a bug waiting to happen,
## and a player who typed `<b>` should see `<b>`.

const API := "https://api.telegram.org"

## Longer than the server's own send, because a phone may be resuming from a
## cold radio rather than talking to a machine on the same desk.
const TIMEOUT := 8.0

## Telegram rejects anything above this with a 400 rather than truncating.
const MAX_MESSAGE := 4096

## Written by `scripts/bake-telegram.mjs`. Absent in a plain checkout, and a
## missing file simply means this relay is not available.
const CONFIG_PATH := "res://telegram_config.gd"

var _token := ""
var _chat_id := ""


func _ready() -> void:
	process_priority = -40
	_load_config()


## True when a token and a chat id are baked in, so a send has somewhere to go.
func is_configured() -> bool:
	return _token != "" and _chat_id != ""


## Sends one queue entry. Returns `{ok: true}` or `{ok: false, error: ...}`;
## never raises, because the caller is a player's suggestion and must survive a
## failed request by staying queued.
func send_item(item: Dictionary) -> Dictionary:
	if not is_configured():
		return {"ok": false, "error": "no bot credentials in this build"}
	var text := str(item.get("text", "")).strip_edges()
	if text.is_empty():
		return {"ok": false, "error": "empty suggestion"}
	var author := str(item.get("author", "")).strip_edges()
	var message := text
	if author != "":
		message += "\n\n— " + author
	if message.length() > MAX_MESSAGE:
		message = message.substr(0, MAX_MESSAGE)
	var http := HTTPRequest.new()
	http.timeout = TIMEOUT
	add_child(http)
	var body := JSON.stringify({
		"chat_id": _chat_id,
		"text": message,
		# The suggestion is player input: a URL in it must not become a tappable
		# preview on the owner's phone.
		"disable_web_page_preview": true,
	})
	var err := http.request(
		"%s/bot%s/sendMessage" % [API, _token],
		PackedStringArray(["Content-Type: application/json"]),
		HTTPClient.METHOD_POST,
		body
	)
	if err != OK:
		http.queue_free()
		return {"ok": false, "error": "request refused (error %d)" % err}
	var results: Array = await http.request_completed
	http.queue_free()
	if results.size() < 4:
		return {"ok": false, "error": "no answer from Telegram"}
	var code: int = int(results[1])
	var payload: PackedByteArray = results[3]
	if code < 200 or code >= 300:
		return {"ok": false, "error": "Telegram %d: %s" % [code, _describe(payload)]}
	var parsed: Variant = JSON.parse_string(payload.get_string_from_utf8())
	var message_id := 0
	if parsed is Dictionary:
		var result: Variant = (parsed as Dictionary).get("result", {})
		if result is Dictionary:
			message_id = int((result as Dictionary).get("message_id", 0))
	return {"ok": true, "messageId": message_id}


## The owner-readable half of a Telegram error body. It names the cause — a bad
## chat id and a revoked token look identical from the status code alone, and
## they are fixed in different files.
func _describe(payload: PackedByteArray) -> String:
	var parsed: Variant = JSON.parse_string(payload.get_string_from_utf8())
	if not (parsed is Dictionary):
		return payload.get_string_from_utf8().left(160)
	var description := str((parsed as Dictionary).get("description", "")).strip_edges()
	return description if description != "" else "unknown error"


func _load_config() -> void:
	if not FileAccess.file_exists(CONFIG_PATH):
		return
	var script: Variant = load(CONFIG_PATH)
	if script == null:
		return
	_token = str(script.TOKEN)
	_chat_id = str(script.CHAT_ID)