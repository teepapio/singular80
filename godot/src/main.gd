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

	# No full-rect Control may be added here. `Control` defaults to
	# `MOUSE_FILTER_STOP`, and Godot hands a click to the topmost Control that
	# stops it — so an invisible, empty, full-screen `Control` in the main scene
	# swallows every mouse and touch event on **every 2D screen**: the top bar,
	# the game cards of the list lobby, the footer buttons. It painted nothing,
	# which is why it was invisible in every screenshot and in every test —
	# the screen sweep switches screens and calls methods, it never clicks.
	#
	# The theme is already set on `Router.screen_host`, on every `Screen`, on
	# `WorldScreen.hud_root` and on every dialog root, so this node carried
	# nothing but the bug. 3D screens were unaffected: their HUD lives on a
	# `CanvasLayer`, which is picked separately from the root canvas.
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
