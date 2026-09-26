class_name SuggestionQueue
extends RefCounted
## Die Warteschlange für Spielervorschläge — Regeln, Format und Ablage.
##
## Netzfrei und renderer-frei, damit sich alles ohne Server prüfen lässt. Die
## Liste selbst ist ein schlichtes `Array[Dictionary]`, das `Api` hält; hier
## stehen die Entscheidungen drumherum:
##
## 1. Jeder Eintrag bekommt beim Einpflegen einen `clientKey` und behält ihn für
##    alle Wiederholungen. Der Server dedupliziert daran — der Client vergleicht
##    nie Texte, denn zwei wirklich gleiche Ideen desselben Spielers sind
##    erlaubt und gehören beide dem Spieler.
## 2. Die Liste steht in `user://` und wird bei **jeder** Änderung geschrieben,
##    bevor ein Senden als Erfolg gilt. Bricht der Prozess mitten im Versand ab,
##    kostet das eine Wiederholung, nicht die Idee.
##
## Alles hier ist bewusst `static`: die Warteschlange ist Daten, kein Objekt mit
## eigenem Leben.

## Ablage der Warteschlange. Über `user://` überlebt sie App-Kill, Reboot und
## Absturz — anders als eine Liste im Arbeitsspeicher.
const PATH := "user://suggestions.json"

## Formatversion der Datei. Eine fremde Version wird verworfen, nicht geraten.
const VERSION := 1

## Obergrenze. Eine unbegrenzte Datei in `user://` ist schlechter als eine
## sichtbare Lücke: im Zweifel weicht der **älteste** Eintrag.
const MAX_ITEMS := 50

## Der Server nimmt 2000 Zeichen an. Ein längerer Eintrag in der Warteschlange
## wäre beim Flush nur ein abgelehnter Request.
const MAX_TEXT := 2000

## Länge des `clientKey` laut Vertrag mit dem Server.
const CLIENT_KEY_MAX := 64

## Wartezeit nach einem fehlgeschlagenen Zustellversuch, in Sekunden. Der
## Versuch 1 wartet nicht, danach 15 → 24 → 38 → 61 → 98 → 157 → 251 → 300.
## Ohne Deckel wäre eine Nacht ohne Netz ein Endlosschleifen-Netzverkehr.
const BACKOFF_BASE := 15.0
const BACKOFF_FACTOR := 1.6
const BACKOFF_MAX := 300.0


# --- Einpflegen -------------------------------------------------------------

## Der Eintrag, wie er in der Warteschlange steht. `clientKey` und `queuedAt`
## entstehen genau hier und bleiben danach unverändert.
static func make_item(text: String, author: String, source: String = "game") -> Dictionary:
	return {
		"clientKey": new_client_key(),
		"queuedAt": int(Time.get_unix_time_from_system()),
		"text": text,
		"author": author,
		"source": source,
	}


## Nimmt einen Eintrag auf die Liste. Gibt den **ältesten verworfenen** Eintrag
## zurück, falls die Grenze gerissen wurde — leer heißt: nichts ging verloren.
static func push(items: Array, item: Dictionary, limit: int = MAX_ITEMS) -> Dictionary:
	var stored := sanitise(item)
	if find(items, str(stored.get("clientKey", ""))) != {}:
		# Doppelte Schlüssel verschmelzen serverseitig zu einem Vorschlag, und
		# der zweite verschwände dabei ohne Spur.
		stored["clientKey"] = new_client_key()
	items.append(stored)
	var dropped := {}
	var cap := maxi(limit, 1)
	while items.size() > cap:
		var victim: Dictionary = items.pop_front()
		if dropped.is_empty():
			dropped = victim
	return dropped


## Nimmt einen Eintrag heraus. Erst der Server bestätigt einen Versand, dann
## verschwindet er hier — und der Aufrufer schreibt das sofort auf die Platte.
static func remove(items: Array, client_key: String) -> bool:
	for i in items.size():
		var entry: Variant = items[i]
		if not (entry is Dictionary):
			continue
		if str((entry as Dictionary).get("clientKey", "")) == client_key:
			items.remove_at(i)
			return true
	return false


## Der Eintrag mit diesem `clientKey`, oder `{}`.
static func find(items: Array, client_key: String) -> Dictionary:
	for entry in items:
		if not (entry is Dictionary):
			continue
		if str((entry as Dictionary).get("clientKey", "")) == client_key:
			return (entry as Dictionary).duplicate()
	return {}


## Wie viele verschiedene `clientKey` die Liste trägt. Zwei Zeilen mit gleichem
## Schlüssel wären ein stiller Verlust auf der Gegenseite.
static func distinct_keys(items: Array) -> int:
	var seen := {}
	for entry in items:
		if entry is Dictionary:
			seen[str((entry as Dictionary).get("clientKey", ""))] = true
	return seen.size()


# --- Ablage -----------------------------------------------------------------

## Liest die Warteschlange von der Platte und repariert sie gleich. Fehlt die
## Datei, ist das kein Fehler: dann hat der Spieler noch nichts gespeichert.
static func restore(path: String = PATH, limit: int = MAX_ITEMS) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if not FileAccess.file_exists(path):
		return out
	out = decode(FileAccess.get_file_as_string(path))
	var cap := maxi(limit, 1)
	if out.size() > cap:
		# Der Überhang stammt aus einer Zeit mit größerem Limit: das Neueste
		# gewinnt, das Alte ist ohnehin am wenigsten wert.
		out = out.slice(out.size() - cap)
	# Sofort neu schreiben: `decode()` hat fehlende Schlüssel ergänzt und
	# Dubletten entfernt, und ab hier ist der Plattenstand die Wahrheit, die ein
	# Absturz nicht mehr beschädigen kann.
	persist(path, out)
	return out


## Schreibt die Warteschlange atomar: erst eine Temp-Datei, dann umbenennen.
## Bricht der Prozess dazwischen ab, ist die alte Liste noch da statt einer
## halben Datei.
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
		push_warning("Vorschlags-Warteschlange nicht schreibbar: %s" % path)
		return false
	file.store_string(text)
	file.close()
	return true


# --- Reines Format ----------------------------------------------------------

static func encode(items: Array) -> String:
	var out: Array = []
	for entry in items:
		var item := sanitise(entry)
		if not item.is_empty():
			out.append(item)
	return JSON.stringify({"version": VERSION, "items": out}, "  ")


## Liest das JSON-Format und repariert, was nicht in Ordnung ist: fehlende oder
## zu lange `clientKey` werden ersetzt, gleiche Schlüssel bekommen einen neuen,
## Einträge ohne Text fliegen raus. Eine kaputte Datei ergibt eine leere Liste
## statt einen Absturz.
static func decode(text: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var parsed: Variant = JSON.parse_string(text)
	var raw: Variant = null
	if parsed is Dictionary:
		raw = (parsed as Dictionary).get("items", [])
	elif parsed is Array:
		# Toleranz für eine nackte Liste, falls die Datei von Hand entstand.
		raw = parsed
	if not (raw is Array):
		return out
	var seen := {}
	for entry in (raw as Array):
		var item := sanitise(entry)
		if item.is_empty() or str(item.get("text", "")) == "":
			continue
		if seen.has(item.get("clientKey", "")):
			# Zwei Einträge mit gleichem Schlüssel würden serverseitig zu einem
			# verschmelzen — der zweite ginge dabei still verloren.
			item["clientKey"] = new_client_key()
		seen[item.get("clientKey", "")] = true
		out.append(item)
	return out


## Bringt einen Eintrag auf die Felder, die der Server kennt. Alles andere wird
## verworfen: die Warteschlange ist kein Archiv.
static func sanitise(entry: Variant) -> Dictionary:
	var out := {}
	if not (entry is Dictionary):
		return out
	var source: Dictionary = entry
	var text := str(source.get("text", "")).strip_edges()
	if text.length() > MAX_TEXT:
		text = text.substr(0, MAX_TEXT)
	var key := str(source.get("clientKey", "")).strip_edges()
	if key.is_empty() or key.length() > CLIENT_KEY_MAX:
		key = new_client_key()
	var queued_at := int(source.get("queuedAt", 0))
	var author := str(source.get("author", "")).strip_edges()
	out["clientKey"] = key
	out["queuedAt"] = queued_at if queued_at > 0 else int(Time.get_unix_time_from_system())
	out["text"] = text
	out["author"] = author if author != "" else "Anonym"
	out["source"] = str(source.get("source", "game")).strip_edges()
	return out


## Der POST-Body für einen Eintrag. `clientKey` liegt oben und bleibt über alle
## Wiederholungen gleich — genau daran dedupliziert der Server.
static func request_body(item: Dictionary) -> Dictionary:
	var clean := sanitise(item)
	return {
		"text": str(clean.get("text", "")),
		"author": str(clean.get("author", "Anonym")),
		"source": str(clean.get("source", "game")),
		"clientKey": str(clean.get("clientKey", "")),
	}


# --- Entscheidungen ---------------------------------------------------------

## Wartezeit vor dem nächsten Versuch. Stufe 0 wartet nicht — direkt nach einer
## Zustandsänderung (neue Idee, App wieder im Vordergrund) soll es losgehen.
static func backoff_seconds(attempt: int) -> float:
	if attempt <= 0:
		return 0.0
	var wait := BACKOFF_BASE
	for _i in maxi(attempt - 1, 0):
		wait *= BACKOFF_FACTOR
		if wait >= BACKOFF_MAX:
			return BACKOFF_MAX
	return minf(wait, BACKOFF_MAX)


## Der Text, den ein Bildschirm zum Wartestand zeigen kann. Leer ohne
## Warteschlange, damit die Anzeige sich selbst versteckt, statt „0 warten“ zu
## behaupten.
static func pending_hint(count: int) -> String:
	if count <= 0:
		return ""
	if count == 1:
		return "1 Vorschlag wartet auf Netz"
	return "%d Vorschläge warten auf Netz" % count


## Die Begründung, wenn die Liste zu voll war. Ein verworfener Vorschlag braucht
## einen sichtbaren Grund, sonst merkt der Spieler erst davon, wenn die Liste
## wieder leer ist.
static func cap_warning(dropped_item: Dictionary, limit: int) -> String:
	var text := str(dropped_item.get("text", "")).strip_edges()
	if text.length() > 40:
		text = text.substr(0, 40) + " …"
	return "Warteschlange voll (höchstens %d) — der älteste Vorschlag wurde verworfen: „%s“" % [limit, text]


## Ein zufälliger, stabiler Schlüssel: einmal erzeugt, dann für alle Versuche
## dieses Vorschlags identisch. Kurz genug für das 64-Zeichen-Limit des Servers
## und eindeutig genug für zwei Ideen im selben Sekunden-Takt.
static func new_client_key() -> String:
	return "s80_%08x%06x" % [
		randi() & 0xFFFFFFFF,
		int(Time.get_unix_time_from_system() * 1000.0) & 0xFFFFFF,
	]
