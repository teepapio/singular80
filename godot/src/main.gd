extends Node
## Entry point of Singular 80.
##
## Loads the content, warms up the backend connection in the background and
## hands control to the 3D lobby. Everything else is reached through
## `Router.go_to`.

func _ready() -> void:
	RenderingServer.set_default_clear_color(UiTheme.BG)
	# Landscape on phones and tablets — lobby and action games want width.
	DisplayServer.screen_set_orientation(DisplayServer.SCREEN_LANDSCAPE)

	# Language first: `Ui` translates captions as they are created, and the first
	# screen is created right now. Without this, its header would use the device
	# language while the rest of the game uses the stored one.
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
	# Start the content fetch BEFORE probing, then await it only if the server
	# answered. Probing and fetching are independent requests, and `Api` hands out
	# one lock for both — so fetching first and probing second leaves the lock
	# free by the time `flush_queue` needs it. Doing it the other way round let the
	# retry timer `Api._ready` armed win the lock, and the queued suggestions were
	# then flushed into a request that returned without sending.
	# `reload_remote` is a coroutine and returns void, so it is started, not awaited
	# into a value.
	Content.reload_remote()
	if await Api.probe():
		await Content.reload_remote()
	Api.flush_queue()
