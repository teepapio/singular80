extends Node
## Bridge between the app and the Android test farm.
##
## Inert unless started with `--devfarm`: it then talks to the farm over HTTP and
## executes commands. The farm drives the app through the same inputs a player
## uses — `tap` sends an `InputEventScreenTouch`, `key` presses an InputMap
## action, `goto` calls the router — so there is no test channel bypassing the
## game.
##
## The default `10.0.2.2` is the host loop as seen from an emulator; on a real
## device `config.json` carries the LAN address instead.

## Nothing happens unless this variable is set.
const FLAG := "--devfarm"

## How long the app waits for a command before asking again. Shorter means
## higher command throughput, longer less idle spinning in the emulator.
const POLL_TIMEOUT_SECONDS := 20.0

## How long to wait for the farm before the attempt counts as a single try.
const CONNECT_TIMEOUT_SECONDS := 12.0

var _bridge := ""
var _id := ""
var _active := false
var _busy := false
var _tries := 0


func _ready() -> void:
	if not OS.get_cmdline_user_args().has(FLAG) and not OS.get_cmdline_args().has(FLAG):
		# Disappear at once without the flag: `queue_free` on an autoload would
		# error on every single start.
		_active = false
		set_process(false)
		return
	_active = true
	var pos := OS.get_cmdline_user_args().find(FLAG)
	var host := "10.0.2.2:8731"
	if pos >= 0:
		var maybe := OS.get_cmdline_user_args()
		if pos + 1 < maybe.size() and maybe[pos + 1].contains(":"):
			host = maybe[pos + 1]
	_bridge = "http://%s" % host
	print("[devfarm] aktiv, Farm unter %s" % _bridge)
	_run()


func _run() -> void:
	while _active:
		if not await _register():
			_tries += 1
			# Retrying forever would only waste battery: the farm sometimes comes
			# up later than the app.
			if _tries > 20:
				print("[devfarm] Farm nicht erreichbar, gebe auf")
				return
			await get_tree().create_timer(2.0).timeout
			continue
		_tries = 0
		while _active:
			var command := await _next_command()
			if command.is_empty():
				break
			await _execute(command)


## Registers and gets the farm's address.
func _register() -> bool:
	var body := JSON.stringify({
		"device": OS.get_name(),
		"model": OS.get_model_name(),
		"godot": Engine.get_version_info().get("string", "?"),
		"screen": DisplayServer.window_get_size(),
	})
	var result := await _request("/register", HTTPClient.METHOD_POST, body)
	if result.is_empty():
		return false
	var parsed: Variant = JSON.parse_string(result)
	if not (parsed is Dictionary):
		return false
	_id = str((parsed as Dictionary).get("id", ""))
	return _id != ""


## Waits for the next command. Empty means: deregister and register again.
func _next_command() -> Dictionary:
	var result := await _request("/next?id=%s" % _id, HTTPClient.METHOD_GET, "")
	if result.is_empty():
		return {}
	var parsed: Variant = JSON.parse_string(result)
	return parsed as Dictionary if parsed is Dictionary else {}


func _request(path: String, method: int, body: String) -> String:
	var request := HTTPRequest.new()
	add_child(request)
	request.timeout = CONNECT_TIMEOUT_SECONDS if method == HTTPClient.METHOD_POST else (POLL_TIMEOUT_SECONDS + 5.0)
	var headers := ["Content-Type: application/json"]
	var error := request.request(_bridge + path, headers, method, body)
	if error != OK:
		request.queue_free()
		return ""
	var done: Array = await request.request_completed
	request.queue_free()
	if done.size() < 4 or int(done[0]) != HTTPRequest.RESULT_SUCCESS:
		return ""
	return str(done[3])


## Runs a command. An unknown one is reported as a finding, not swallowed — a
## silently ignored command looks like a game bug in the farm.
func _execute(command: Dictionary) -> void:
	if _busy:
		await _event("busy", {"op": str(command.get("op", "?"))})
		return
	_busy = true
	var op := str(command.get("op", ""))
	var payload: Variant = command.get("args", {})
	var args: Dictionary = payload if payload is Dictionary else {}

	match op:
		"ping":
			await _event("pong", {"t": Time.get_ticks_msec()})
		"goto":
			var id := str(args.get("screen", ""))
			Router.go_to(id, args.get("data", {}))
			await get_tree().create_timer(float(args.get("settle", 0.6))).timeout
			await _event("screen", {"screen": id, "current": _current_screen_id()})
		"audit":
			var screen := _current_screen()
			var findings: Array[Dictionary] = []
			if screen is Control:
				findings = await DevFarmAudit.audit_screen(screen as Control, get_tree())
			else:
				findings = [{"kind": "no-screen", "severity": "fail", "where": "-", "message": "Kein 2D-Bildschirm geladen."}]
			await _event("audit", {"screen": _current_screen_id(), "findings": findings})
		"tap":
			_tap(Vector2(float(args.get("x", 0.0)), float(args.get("y", 0.0))), float(args.get("hold", 0.05)))
			await get_tree().create_timer(float(args.get("after", 0.25))).timeout
		"tap_button":
			# Taps the button whose caption matches: the farm knows no screen
			# coordinates, and those differ between devices anyway.
			await _tap_named(str(args.get("text", "")), get_tree())
		"key":
			var action := str(args.get("action", ""))
			if not action.is_empty():
				Input.action_press(action)
				await get_tree().create_timer(float(args.get("hold", 0.08))).timeout
				Input.action_release(action)
		"soak":
			await _soak(float(args.get("seconds", 10.0)), int(args.get("seed", 0)), args)
		"metrics":
			await _event("metrics", {
				"fps": Engine.get_frames_per_second(),
				"staticMemory": Performance.get_monitor(Performance.MEMORY_STATIC),
				"objects": Performance.get_monitor(Performance.OBJECT_COUNT),
				"drawCalls": Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
				"nodes": Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
			})
		"shot":
			await _screenshot()
		"quit":
			await _event("bye", {})
			_active = false
			get_tree().quit()
			return
		_:
			await _event("error", {"message": "Unbekannter Befehl: %s" % op})
	_busy = false


func _current_screen() -> Node:
	return Router.current_screen if Router != null else null


func _current_screen_id() -> String:
	return Router.current_id if Router != null else ""


## A real tap, exactly the one a finger produces.
##
## The path goes through `push_input`, **not** `Input.parse_input_event`: the
## latter never reaches the viewport's GUI, so a click sent that way moves
## nothing. And **both** events are sent: the touch first, then the click derived
## from it via `pointing/emulate_mouse_from_touch` — which is what a `Button`
## listens to at all. A device sends exactly this.
func _tap(point: Vector2, hold: float) -> void:
	var viewport := get_viewport()
	_push(viewport, _touch(point, true))
	await get_tree().create_timer(hold).timeout
	_push(viewport, _mouse(point, false))
	_push(viewport, _touch(point, false))


func _push(viewport: Viewport, event: InputEvent) -> void:
	viewport.push_input(event, true)


func _touch(point: Vector2, pressed: bool) -> InputEventScreenTouch:
	var event := InputEventScreenTouch.new()
	event.index = 0
	event.pressed = pressed
	event.position = point
	return event


func _mouse(point: Vector2, pressed: bool) -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = pressed
	event.position = point
	event.global_position = point
	return event


## Taps the first button whose caption contains `needle`.
func _tap_named(needle: String, tree: SceneTree) -> void:
	var screen := _current_screen()
	if not (screen is Control):
		await _event("error", {"message": "Kein 2D-Bildschirm geladen."})
		return
	var needle_lower := needle.to_lower()
	for control in DevFarmAudit.interactive_controls(screen as Control):
		if not (control is BaseButton):
			continue
		var text := str((control as BaseButton).text).strip_edges()
		if text.to_lower().find(needle_lower) == -1:
			continue
		_tap((control as Control).get_global_rect().get_center(), 0.05)
		await _event("tapped", {"text": text})
		await tree.create_timer(0.25).timeout
		return
	await _event("error", {"message": "Kein Knopf mit '%s' gefunden." % needle})


## Plays sensible input for a while, to drive the game.
##
## Deliberately **not** a random key storm: the actions come from the open game's
## InputMap, so they are the inputs that actually do something there. A storm of
## arbitrary keys finds nothing and only adds noise to the report.
func _soak(seconds: float, seed_value: int, args: Dictionary) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value if seed_value != 0 else int(Time.get_ticks_msec())
	var actions: Array = args.get("actions", [])
	if actions.is_empty():
		actions = _default_actions()
	var deadline := Time.get_ticks_msec() + int(seconds * 1000.0)
	var performed := 0
	while Time.get_ticks_msec() < deadline:
		var action := str(actions[rng.randi_range(0, actions.size() - 1)])
		Input.action_press(action)
		await get_tree().create_timer(rng.randf_range(0.04, 0.14)).timeout
		Input.action_release(action)
		performed += 1
		await get_tree().create_timer(rng.randf_range(0.05, 0.25)).timeout
	await _event("soak", {"performed": performed, "seconds": seconds})


## The actions that do something in-game — the core of the InputMap.
func _default_actions() -> Array:
	var out: Array = ["ui_accept", "ui_left", "ui_right", "ui_down", "dash", "fire"]
	return out


func _screenshot() -> void:
	var image := get_viewport().get_texture().get_image()
	if image == null:
		await _event("error", {"message": "Kein Bild verfügbar."})
		return
	var out := "user://devfarm-shot.png"
	image.save_png(out)
	# The file lands in the app's data directory, reachable through adb
	# (`/data/data/<package>/files`); the farm pulls it and deletes it after.
	var absolute := ProjectSettings.globalize_path(out)
	await _event("shot", {"path": absolute, "size": [image.get_width(), image.get_height()]})


func _event(type: String, data: Dictionary) -> void:
	var body := JSON.stringify({"id": _id, "type": type, "data": data})
	var request := HTTPRequest.new()
	add_child(request)
	request.timeout = 5.0
	request.request(_bridge + "/event", ["Content-Type: application/json"], HTTPClient.METHOD_POST, body)
	await request.request_completed
	request.queue_free()
