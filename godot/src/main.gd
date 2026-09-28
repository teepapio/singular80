extends Node
## Entry point of Singular 80.
##
## Loads the content, warms up the backend connection in the background and
## hands control to the 3D lobby. Everything else is reached through
## `Router.go_to`.

func _ready() -> void:
	RenderingServer.set_default_clear_color(UiTheme.BG)
	# Landscape on phones and tablets — the lobby and every action game are
	# designed around a wide viewport.
	DisplayServer.screen_set_orientation(DisplayServer.SCREEN_LANDSCAPE)

	# Before anything else: load the language. `Ui` translates every caption as it
	# is created, and the first screen is created right now — without this call the
	# lobby header would be in the device language and the rest in the stored one,
	# which looks like a bug and is not.
	Loc.boot()

	Content.reload()

	var settings := Control.new()
	settings.name = "Settings"
	settings.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	settings.theme = UiTheme.shared()
	add_child(settings)

	Router.go_to("lobby")

	# Probe the backend off the critical path so startup stays instant.
	_bootstrap_backend.call_deferred()


func _bootstrap_backend() -> void:
	if not Game.has_server():
		return
	if await Api.probe():
		await Content.reload_remote()
	Api.flush_queue()
