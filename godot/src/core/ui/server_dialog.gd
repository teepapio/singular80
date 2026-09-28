class_name ServerDialog
extends RefCounted
## Input dialog for the Singular 80 backend address.
##
## A shared UI like `SuggestDialog`, reachable from every screen and not just
## from one game's menu.
## Saving also wakes the suggestion queue; otherwise it idles out its backoff
## even though the address is now right.

## The one open window. It is a child of the settings layer and used to be left
## behind: every settings → server cycle added another hidden `AcceptDialog`.
static var _dialog: AcceptDialog = null


static func is_open() -> bool:
	return _dialog != null and is_instance_valid(_dialog)


## Opens the dialog on `host` and applies the new address on confirm.
static func open(host: Node) -> void:
	if is_open():
		return
	var dialog := AcceptDialog.new()
	# `AcceptDialog`'s own buttons take their captions from `TranslationServer`;
	# `Loc` does not register our catalogues under Godot's `ok`/`cancel` keys.
	dialog.ok_button_text = Loc.t("ui.ok")
	dialog.title = Loc.t("ui.server_title")
	dialog.dialog_hide_on_ok = true
	var row := VBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var edit := LineEdit.new()
	edit.placeholder_text = "http://192.168.1.20:8787"
	edit.text = Game.server_url
	edit.custom_minimum_size = Vector2(400, 42)
	row.add_child(edit)
	var hint := Ui.label(Loc.t("ui.server_hint"), 14, UiTheme.TEXT_DIM)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size = Vector2(400, 52)
	row.add_child(hint)
	dialog.add_child(row)
	dialog.confirmed.connect(func() -> void:
		apply(edit.text)
		close()
	)
	# ESC, the close button and the platform's back gesture all end in
	# `canceled` / `close_requested`; without them the window hides and stays.
	dialog.canceled.connect(close)
	dialog.close_requested.connect(close)
	host.add_child(dialog)
	_dialog = dialog
	dialog.popup_centered()


## Frees the window. Safe to call twice — `AcceptDialog` reports both a
## cancel and a close request for one dismissal.
static func close() -> void:
	if _dialog != null and is_instance_valid(_dialog):
		# Hide before freeing: a window removed while still visible leaves the
		# embedded subwindow of the settings dialog one frame behind.
		_dialog.hide()
		_dialog.queue_free()
	_dialog = null


## Sets the address and everything that has to follow it.
## `Api.wake()` is the easy part to forget and expensive to skip: the queue would
## sit out its backoff (up to `BACKOFF_MAX`, five minutes) with the address right.
static func apply(url: String) -> void:
	Game.set_server_url(url)
	Content.reload_remote.call_deferred()
	Api.wake()


## The caption of the button that opens this dialog.
## `Loc.t` with a `{state}` placeholder rather than `"… %s" % url`, so a language
## that puts the word in front of the colon still reads right.
static func label() -> String:
	return Loc.t("ui.server_caption", {
		"state": Loc.t("ui.server_offline") if not Game.has_server() else Game.server_url,
	})
