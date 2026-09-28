extends Screen
## Game over summary for the arena. Port of `scenes/GameOverScene.ts`.

func _ready_game() -> void:
	var score := int(data.get("score", 0))
	var kills := int(data.get("kills", 0))
	var time_ms := float(data.get("timeMs", 0.0))
	var level := int(data.get("level", 1))
	var mode_id := str(data.get("modeId", "classic"))
	var weapon_id := str(data.get("weaponId", "pistol"))

	var is_record := score > Game.highscore(Game.HS_ARENA)
	if is_record:
		Game.submit_score(Game.HS_ARENA, score)

	var background := Ui.rect(Color(0.110, 0.039, 0.039))
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	content_layer().add_child(background)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# A layout container has no `gui_input` of its own, but it defaults to
	# `MOUSE_FILTER_STOP` and picking ignores `z_index` — so a full-rect
	# container added after the top bar would swallow the ⚙, "◀ Lobby" and mute
	# buttons underneath it. `CHROME_Z` only fixes the painting, not the click.
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content_layer().add_child(center)

	var column := Ui.vbox(14)
	column.alignment = BoxContainer.ALIGNMENT_CENTER
	center.add_child(column)

	column.add_child(Ui.title("GAME OVER", 66, Color(0.973, 0.443, 0.443)))
	if is_record:
		column.add_child(Ui.label("★  New high score!  ★", 24, Color(0.980, 0.800, 0.086), true))
	else:
		column.add_child(Ui.label(Loc.f("High score: %s", [Ui.format_number(Game.highscore(Game.HS_ARENA))]), 20, UiTheme.TEXT_DIM, true))

	column.add_child(Ui.spacer(Vector2(0, 10)))
	column.add_child(Ui.label(
		Loc.f("Score: %s     ·     Kills: %d     ·     Level: %d     ·     Time: %s", [Ui.format_number(score), kills, level, Ui.format_time(time_ms),]), 24, Color(0.886, 0.910, 0.941)))
	column.add_child(Ui.spacer(Vector2(0, 18)))

	var row := Ui.hbox(16)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	column.add_child(row)
	row.add_child(Ui.button("🔁  Again", Vector2(320, 62), UiTheme.ACCENT, func() -> void:
		Sfx.select()
		Router.go_to("arena", {"weaponId": weapon_id, "modeId": mode_id})
	))
	row.add_child(Ui.button("Suggestion", Vector2(320, 62), UiTheme.PANEL_LIGHT, func() -> void:
		SuggestDialog.open(self)
	))
	row.add_child(Ui.button("◀  Lobby", Vector2(320, 62), UiTheme.PANEL_LIGHT, func() -> void:
		Router.to_lobby()
	))

	column.add_child(Ui.spacer(Vector2(0, 14)))
	column.add_child(Ui.label(
		"Just thought of something? Submit it — maybe it is in the game next time.",
		15, UiTheme.TEXT_MUTED))
