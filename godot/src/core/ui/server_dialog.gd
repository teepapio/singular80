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

## Opens the dialog on `host` and applies the new address on confirm.
static func open(host: Node) -> void:
	var dialog := AcceptDialog.new()
	# Godot's `AcceptDialog` brings its own buttons, whose captions live in
	# `TranslationServer`. They are not in play here: `Loc` does not register its
	# catalogues under Godot's `ok`/`cancel` names, and a button that says "OK" in
	# every language is the smallest crack in this dialog.
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


## The caption of the button that opens this dialog.
##
## `Loc.t` with a `{state}` placeholder rather than `"… %s" % url`: the address is
## substituted *after* the template has been translated, so a language that puts
## the word in front of the colon still reads correctly. The address itself stays
## untranslated, which is the point — `192.168.1.20:8787` is not prose.
static func label() -> String:
	return Loc.t("ui.server_caption", {
		"state": Loc.t("ui.server_offline") if not Game.has_server() else Game.server_url,
	})
