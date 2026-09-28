class_name SuggestionQueue
extends RefCounted
## Queue for player suggestions — rules, format, storage. Network-free and
## renderer-free, so everything tests without a server.
## The list itself is a plain `Array[Dictionary]` held by `Api`; what lives here
## are the decisions around it:
##
## 1. Every entry gets a `clientKey` on insert and keeps it across retries. The
##    server dedupes on it — the client never compares texts: two identical ideas
##    from one player are allowed.
## 2. The list lives in `user://` and is written on **every** change before a send
##    counts as success. If the process dies mid-send, that costs a retry, not the
##    idea.
##
## Everything here is deliberately `static`: the queue is data.

## Storage path. Survives app kill, reboot and crash via `user://` — unlike a
## list in RAM.
const PATH := "user://suggestions.json"

## File format version. A foreign version is discarded, not guessed at.
const VERSION := 1

## Upper limit. An unbounded file in `user://` is worse than a visible gap: the
## **oldest** entry yields.
const MAX_ITEMS := 50

## The server accepts 2000 characters; longer entries would only be rejected at
## flush time.
const MAX_TEXT := 2000

## Length of the `clientKey` per the server contract.
const CLIENT_KEY_MAX := 64

## Wait after a failed delivery attempt, in seconds. Attempt 1 does not wait, then
## 15 → 24 → 38 → 61 → 98 → 157 → 251 → 300. Without a cap, a night without network
## would mean endless retries.
const BACKOFF_BASE := 15.0
const BACKOFF_FACTOR := 1.6
const BACKOFF_MAX := 300.0

## The queue's own generator, seeded once from the system entropy. Godot does not
## seed the global `randi()` at startup, and nothing in this game calls
## `randomize()`, so two launches drew the very same sequence — and the key is
## what the whole dedupe story rests on.
static var _rng: RandomNumberGenerator


# --- Insert -----------------------------------------------------------------

## The entry as it sits in the queue. `clientKey` and `queuedAt` are born here and
## never change after.
static func make_item(text: String, author: String, source: String = "game") -> Dictionary:
	return {
		"clientKey": new_client_key(),
		"queuedAt": int(Time.get_unix_time_from_system()),
		"text": text,
		"author": author,
		"source": source,
	}


## Appends an entry. Returns the **oldest dropped** entry if the limit was hit —
## empty means nothing was lost.
static func push(items: Array, item: Dictionary, limit: int = MAX_ITEMS) -> Dictionary:
	var stored := sanitise(item)
	if find(items, str(stored.get("clientKey", ""))) != {}:
	# Duplicate keys would merge server-side into one suggestion, the second
	# vanishing without a trace.
		stored["clientKey"] = new_client_key()
	items.append(stored)
	var dropped := {}
	var cap := maxi(limit, 1)
	while items.size() > cap:
		var victim: Dictionary = items.pop_front()
		if dropped.is_empty():
			dropped = victim
	return dropped


## Removes an entry. Only after the server confirms a send does it disappear — and
## the caller writes that to disk immediately.
static func remove(items: Array, client_key: String) -> bool:
	for i in items.size():
		var entry: Variant = items[i]
		if not (entry is Dictionary):
			continue
		if str((entry as Dictionary).get("clientKey", "")) == client_key:
			items.remove_at(i)
			return true
	return false


## The entry with this `clientKey`, or `{}`.
static func find(items: Array, client_key: String) -> Dictionary:
	for entry in items:
		if not (entry is Dictionary):
			continue
		if str((entry as Dictionary).get("clientKey", "")) == client_key:
			return (entry as Dictionary).duplicate()
	return {}


## How many distinct `clientKey` values the list carries. Two rows with the same
## key would be a silent loss on the server side.
static func distinct_keys(items: Array) -> int:
	var seen := {}
	for entry in items:
		if entry is Dictionary:
			seen[str((entry as Dictionary).get("clientKey", ""))] = true
	return seen.size()


# --- Storage ----------------------------------------------------------------

## Reads the queue from disk and repairs it on the way. A missing file is not an
## error: the player has saved nothing yet.
## `write_back` says whether the repaired list may replace the file. `Api` passes
## its own "this is a real launch" switch, so a `--script` run — which loads the
## autoloads for real — reads the player's suggestions without overwriting them.
static func restore(path: String = PATH, limit: int = MAX_ITEMS, write_back: bool = true) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if not FileAccess.file_exists(path):
		return out
	var text := FileAccess.get_file_as_string(path)
	out = decode(text)
	var cap := maxi(limit, 1)
	if out.size() > cap:
		# Overflow from a time with a higher limit: the newest wins.
		out = out.slice(out.size() - cap)
	# Write back, but only when the repair changed something: `decode()` has
	# filled in missing keys and dropped duplicates, and the on-disk state is
	# then the truth a crash can no longer corrupt. A queue that was already in
	# shape must not cost a write on every single start.
	if write_back and encode(out) != text:
		persist(path, out)
	return out


## Writes the queue atomically: temp file first, then rename. If the process dies in
## between, the old list survives instead of a half-written file.
static func persist(path: String, items: Array) -> bool:
	var text := encode(items)
	var file := FileAccess.open(path + ".tmp", FileAccess.WRITE)
	if file == null:
		return _write_plain(path, text)
	file.store_string(text)
	file.close()
	var from := ProjectSettings.globalize_path(path + ".tmp")
	var to := ProjectSettings.globalize_path(path)
	if DirAccess.rename_absolute(from, to) != OK:
		return _write_plain(path, text)
	return true


static func _write_plain(path: String, text: String) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_warning("Suggestion queue not writable: %s" % path)
		return false
	file.store_string(text)
	file.close()
	return true


# --- Pure format ------------------------------------------------------------

static func encode(items: Array) -> String:
	var out: Array = []
	for entry in items:
		var item := sanitise(entry)
		if not item.is_empty():
			out.append(item)
	return JSON.stringify({"version": VERSION, "items": out}, "  ")


## Reads the JSON format and repairs what is off: missing or over-long `clientKey`
## values are replaced, duplicates get a new one, entries without text are
## dropped. A broken file yields an empty list, not a crash.
static func decode(text: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var parsed: Variant = JSON.parse_string(text)
	var raw: Variant = null
	if parsed is Dictionary:
		raw = (parsed as Dictionary).get("items", [])
	elif parsed is Array:
		# Tolerance for a bare list, in case the file was written by hand.
		raw = parsed
	if not (raw is Array):
		return out
	var seen := {}
	for entry in (raw as Array):
		var item := sanitise(entry)
		if item.is_empty() or str(item.get("text", "")) == "":
			continue
		if seen.has(item.get("clientKey", "")):
			# Two entries with the same key would merge server-side — the second would
			# be silently lost.
			item["clientKey"] = new_client_key()
		seen[item.get("clientKey", "")] = true
		out.append(item)
	return out


## Brings an entry down to the fields the server knows. Everything else is
## discarded: the queue is not an archive.
static func sanitise(entry: Variant) -> Dictionary:
	var out := {}
	if not (entry is Dictionary):
		return out
	var source: Dictionary = entry
	var text := str(source.get("text", "")).strip_edges()
	if text.length() > MAX_TEXT:
		text = text.substr(0, MAX_TEXT)
	var queued_at := int(source.get("queuedAt", 0))
	var author := str(source.get("author", "")).strip_edges()
	out["queuedAt"] = queued_at if queued_at > 0 else int(Time.get_unix_time_from_system())
	out["text"] = text
	out["author"] = author if author != "" else "Anonym"
	out["source"] = str(source.get("source", "game")).strip_edges()
	# The key has to come along. `sanitise` rebuilds the entry, and `ensure_key`
	# mints a new one whenever the field is missing — so without this line every
	# `persist` handed the same idea a different `clientKey`, the server's
	# idempotency on it never fired, and a retry could not be recognised as the
	# suggestion it already had.
	out["clientKey"] = str(source.get("clientKey", ""))
	ensure_key(out)
	return out


## The `clientKey` of an entry, minted once if it has none yet. Every path that
## puts an entry into the queue or sends it goes through here, so the key that is
## stored, the key that is sent and the key a retry looks the entry up with are
## the same string by construction.
static func ensure_key(entry: Dictionary) -> String:
	var key := str(entry.get("clientKey", "")).strip_edges()
	if key.is_empty() or key.length() > CLIENT_KEY_MAX:
		key = new_client_key()
		entry["clientKey"] = key
	return key


## The POST body for one entry. `clientKey` sits on top and stays the same across
## all retries — the server dedupes on exactly that.
static func request_body(item: Dictionary) -> Dictionary:
	var clean := sanitise(item)
	# The key of the entry **as it was handed in**, and `ensure_key` stores one
	# there if it was missing. `clean` is a copy, so its freshly minted key is not
	# the entry's: posting that one would leave the local row — which the caller
	# removes by the key it looked the entry up with — in the queue for good,
	# while the server took the same idea under a new key on every attempt. Three
	# keys, three identical rows in the dashboard: what this file promises cannot
	# happen.
	ensure_key(item)
	return {
		"text": str(clean.get("text", "")),
		"author": str(clean.get("author", "Anonym")),
		"source": str(clean.get("source", "game")),
		"clientKey": str(item.get("clientKey", "")),
	}


# --- Decisions --------------------------------------------------------------

## Wait time before the next attempt. Attempt 0 does not wait — after a state change
## (new idea, app back in foreground) it should go at once.
static func backoff_seconds(attempt: int) -> float:
	if attempt <= 0:
		return 0.0
	var wait := BACKOFF_BASE
	for _i in maxi(attempt - 1, 0):
		wait *= BACKOFF_FACTOR
		if wait >= BACKOFF_MAX:
			return BACKOFF_MAX
	return minf(wait, BACKOFF_MAX)


## The text a screen can show for the pending count. Empty without a queue, so the
## display hides itself instead of claiming "0 waiting".
static func pending_hint(count: int) -> String:
	if count <= 0:
		return ""
	# Plural forms rather than two German sentences. The grammar — French counts
	# zero as singular too — belongs in the catalogue, not in this file; here it is
	# only recorded that there is something to count.
	return Loc.tn("ui.queue_waiting", count)


## The reason shown when the list was too full. A dropped suggestion needs a
## visible reason, otherwise the player only notices when the list is empty again.
static func cap_warning(dropped_item: Dictionary, limit: int) -> String:
	var text := str(dropped_item.get("text", "")).strip_edges()
	if text.length() > 40:
		text = text.substr(0, 40) + " …"
	# `Loc.t` with named placeholders, not `Loc.f` with `%`: the player's own text
	# goes in after the sentence has been translated, so a language that puts the
	# dropped suggestion first still reads correctly. The other way round — format
	# first, translate second — would mean storing a finished sentence with a
	# player's words already inside it.
	return Loc.t("ui.queue_full", {"limit": str(limit), "text": text})


## A random, stable key: generated once, then identical for every attempt of this
## suggestion. Short enough for the server's 64-character limit, unique enough for
## two ideas in the same millisecond.
static func new_client_key() -> String:
	# Not `Loc.f`: this is an identifier the backend stores, and `Loc.f` resolves
	# its values — a resolved value here would mint a different key every time the
	# catalogue changed. Two draws instead of `randi()` plus the millisecond clock:
	# the clock is the same in two processes started in the same millisecond, and
	# the global generator repeats its whole sequence from the second launch on.
	return "s80_%08x%08x" % [
		_random().randi() & 0xFFFFFFFF,
		_random().randi() & 0xFFFFFFFF,
	]


## The queue's generator, seeded on first use.
static func _random() -> RandomNumberGenerator:
	if _rng == null:
		_rng = RandomNumberGenerator.new()
		_rng.randomize()
	return _rng
