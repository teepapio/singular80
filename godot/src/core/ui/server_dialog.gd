class_name ServerDialog
extends RefCounted
## Eingabedialog für die Adresse des Singular-80-Backends.
##
## Der Dialog lag vorher fest in `main_menu_screen.gd` des Arena-Spiels. Das war
## der einzige Weg, sie zu erreichen — wer Tetris spielt und einen Vorschlag
## abschickt, kam am Hauptbildschirm nicht daran vorbei, und die Idee blieb in
## `user://` liegen. Genau das ist der Fehler, den diese Datei behebt: die
## Adresse ist jetzt eine geteilte UI wie der Vorschlagsdialog, und der
## Hauptbildschirm bietet sie an.
##
## Nach dem Speichern wird nicht nur die Adresse gesetzt: eine wartende
## Warteschlange wird sofort angestoßen. Sonst wartet sie bis zu `BACKOFF_MAX`
## Sekunden, obwohl die Adresse jetzt längst stimmt.

const _HINT := "Ohne Adresse läuft das Spiel mit den mitgelieferten Inhalten, und Vorschläge bleiben lokal, bis du sie hier einträgst."


## Opens the dialog on `host` and applies the new address on confirm.
static func open(host: Node) -> void:
	var dialog := AcceptDialog.new()
	dialog.title = "Server-Adresse"
	dialog.dialog_hide_on_ok = true
	var row := VBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var edit := LineEdit.new()
	edit.placeholder_text = "http://192.168.1.20:8787"
	edit.text = Game.server_url
	edit.custom_minimum_size = Vector2(400, 42)
	row.add_child(edit)
	var hint := Ui.label(_HINT, 14, UiTheme.TEXT_DIM)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size = Vector2(400, 52)
	row.add_child(hint)
	dialog.add_child(row)
	dialog.confirmed.connect(func() -> void:
		apply(edit.text)
	)
	host.add_child(dialog)
	dialog.popup_centered()


## Sets the address and everything that has to follow it.
##
## `Api.wake()` is the part that is easy to forget and expensive to skip: without
## it a queue that has been waiting out its backoff sits there for up to
## `BACKOFF_MAX` seconds — five minutes — although the address was right in front
## of the player the whole time. Their idea is in `user://` and they were told it
## is "gespeichert"; the moment the address is known, it should go out.
static func apply(url: String) -> void:
	Game.set_server_url(url)
	Content.reload_remote.call_deferred()
	Api.wake()


## The German text for the button that opens this dialog.
static func label() -> String:
	return "Server: %s" % (Game.server_url if Game.has_server() else "offline")
