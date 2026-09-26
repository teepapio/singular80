extends Node
## Erzeugt echte Screenshots der Spiel-Screens für den Play-Store.
##
## Kopiert von googleplay/scripts/screenshots.mjs nach godot/ (Präfix `_`, wird
## von export_presets.cfg aus jedem Build ausgeschlossen). Der `_`-Prefix ist
## wichtig: das Skript gehört nicht ins AAB.
##
## Aufruf (über screenshots.mjs):
##   godot --headless --path godot res://_playstore_shots.tscn -- <frames> <ziel> <screens...>
##
## Das Zielverzeichnis kommt als drittes Kommandozeilen-Argument (nach `--`),
## damit das Skript ohne weitere Dateien auskommt.

var frames := 4
var target_frames := 4
var out_dir := "/tmp"
var screens: Array[String] = []
## -1, weil `_next()` zuerst hochzählt — bei 0 würde der erste Aufruf sofort fertig melden.
var idx := -1
var done_count := 0


func _ready() -> void:
	Engine.max_fps = 30
	var args := OS.get_cmdline_user_args()
	var pos := 0
	if args.size() > pos:
		frames = int(args[pos])
		target_frames = frames
		pos += 1
	if args.size() > pos:
		out_dir = args[pos]
		pos += 1
	if args.size() > pos:
		for name in args[pos].split(",", false):
			screens.append(name)
	DirAccess.make_dir_recursive_absolute(out_dir)
	print("SHOTS-ARGS ", args, " → ", screens)
	print("SHOTS-DISPLAY ", DisplayServer.get_name(), " adapter=", RenderingServer.get_video_adapter_name())
	# --headless wählt zwingend den Dummy-Renderer: es werden keine Frames
	# gezeichnet, frame_post_draw feuert nie, das Ergebnis wäre ein Schwarzbild.
	# Lieber sofort abbrechen als zehn Minuten auf ein Bild zu warten.
	if DisplayServer.get_name() == "headless":
		print("SHOTS-NO-RENDERER")
		get_tree().quit(3)
		return
	if screens.is_empty():
		push_error("keine Screens angegeben")
		get_tree().quit(1)
		return
	_next()


func _payload_for(name: String) -> Dictionary:
	## "id:key=value;key=value" schaltet Debug-Daten für den Screenshot frei.
	var out := {}
	var parts := name.split(":", true, 1)
	if parts.size() < 2:
		return out
	for pair in parts[1].split(";"):
		var kv := pair.split("=", true, 1)
		if kv.size() == 2:
			out[kv[0].strip_edges()] = kv[1].strip_edges()
	return out


func _next() -> void:
	idx += 1
	if idx >= screens.size():
		print("SHOTS-DONE ", done_count, "/", screens.size())
		get_tree().quit(0)
		return
	var spec := screens[idx]
	var screen_id := spec.split(":", true, 1)[0]
	Router.go_to(screen_id, _payload_for(spec))
	frames = 0


func _process(_delta: float) -> void:
	frames += 1
	if frames < target_frames:
		if frames == 1:
			print("SHOT-FRAMES starten: ", screens, " Ziel ", target_frames, " Frame")
		return
	frames = 0
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	if image == null:
		push_error("kein Bild — headless ohne Renderer?")
		get_tree().quit(1)
		return
	var screen_id := screens[idx].split(":", true, 1)[0]
	var path := "%s/%02d_%s.png" % [out_dir, idx, screen_id]
	image.save_png(path)
	done_count += 1
	print("SAVED ", path, " ", image.get_width(), "x", image.get_height())
	_next()
