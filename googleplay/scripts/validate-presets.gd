extends SceneTree
## Parses export_presets.cfg with Godot's own ConfigFile parser — the only
## reliable check for the Play preset.
##
## ConfigFile only treats `#` as a comment when the line contains no `=`;
## otherwise the export aborts with "Unexpected identifier" and the preset is
## invisible without a clear warning from the editor.
##
## Copied into godot/ by googleplay/scripts/install-export-preset.mjs under a
## `_` prefix, so every build excludes it.
##
##   godot --headless --path godot --script res://_cfgtest.gd -- export_presets.cfg [preset]
##
## Exit 0 = PARSE-OK, 1 = PARSE-ERROR/MISSING, 2 = bad invocation.

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		push_error("usage: _cfgtest.gd <config-file> [preset-name]")
		quit(2)
		return

	var cfg := ConfigFile.new()
	var err := cfg.load(args[0])
	if err != OK:
		print("PARSE-ERROR ", error_string(err))
		quit(1)
		return

	var expected := args[1] if args.size() > 1 else ""
	if expected == "":
		print("PARSE-OK sections=", cfg.get_sections().size())
		quit(0)
		return

	for section in cfg.get_sections():
		if str(cfg.get_value(section, "name", "")) != expected:
			continue
		# Export options live in the sibling `<section>.options` block.
		var options := section + ".options"
		print("PARSE-OK section=", section,
			" name=", expected,
			" format=", cfg.get_value(options, "gradle_build/export_format", "?"),
			" target=", cfg.get_value(options, "gradle_build/target_sdk", "?"),
			" package=", cfg.get_value(options, "package/unique_name", "?"),
			" versionCode=", cfg.get_value(options, "version/code", "?"))
		quit(0)
		return

	print("PARSE-MISSING name=\"", expected, "\" nicht gefunden")
	quit(1)
