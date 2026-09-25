extends Node
## Procedural sound effects.
##
## The browser build synthesised every sound with the Web Audio API; the same
## tones are generated here as short `AudioStreamWAV` buffers, so the app ships
## without any audio assets and still sounds identical in character.

const SAMPLE_RATE := 22050
const MAX_VOICES := 12

var _voices: Array[AudioStreamPlayer] = []
var _next := 0
var _cache: Dictionary = {}


func _ready() -> void:
	process_priority = -50
	for i in MAX_VOICES:
		var player := AudioStreamPlayer.new()
		player.bus = "Master"
		add_child(player)
		_voices.append(player)
	AudioServer.set_bus_mute(0, Game.muted)


## Plays a tone. `type` is one of `square`, `saw`, `tri`, `sine`, `noise`.
func tone(freq: float, duration: float = 0.08, type: String = "square", volume_db: float = -20.0, slide_to: float = 0.0) -> void:
	if Game.muted:
		return
	var key := "%s|%.1f|%.3f|%.1f|%.1f" % [type, freq, duration, volume_db, slide_to]
	var stream: AudioStreamWAV = _cache.get(key, null)
	if stream == null:
		stream = _render(freq, duration, type, slide_to)
		_cache[key] = stream
	var player := _voices[_next]
	_next = (_next + 1) % _voices.size()
	player.stream = stream
	player.volume_db = volume_db
	player.pitch_scale = randf_range(0.97, 1.03)
	player.play()


func _render(freq: float, duration: float, type: String, slide_to: float) -> AudioStreamWAV:
	var count := int(max(1.0, duration) * SAMPLE_RATE)
	var data := PackedByteArray()
	data.resize(count * 2)
	var phase := 0.0
	var phase2 := 0.0
	for i in count:
		var t := float(i) / float(SAMPLE_RATE)
		var progress: float = t / max(0.0001, duration)
		var current := freq
		if slide_to > 0.0:
			current = lerp(freq, max(30.0, slide_to), progress)
		var sample := 0.0
		match type:
			"square":
				phase = fmod(phase + current / float(SAMPLE_RATE), 1.0)
				sample = 1.0 if phase < 0.5 else -1.0
			"saw":
				phase = fmod(phase + current / float(SAMPLE_RATE), 1.0)
				sample = phase * 2.0 - 1.0
			"tri":
				phase = fmod(phase + current / float(SAMPLE_RATE), 1.0)
				sample = 4.0 * absf(phase - 0.5) - 1.0
			"noise":
				sample = randf_range(-1.0, 1.0)
			_:
				phase += current / float(SAMPLE_RATE)
				phase2 = phase - floorf(phase)
				sample = sin(phase2 * TAU)
		# Short attack / exponential decay so nothing clicks.
		var envelope := minf(1.0, t / 0.006) * pow(1.0 - progress, 1.6)
		var value := int(clampf(sample * envelope, -1.0, 1.0) * 26000.0)
		data.encode_s16(i * 2, value)

	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = SAMPLE_RATE
	stream.stereo = false
	stream.data = data
	return stream


# --- named effects (mirrors the browser build's `sfx` object) ---------------

func shoot() -> void:
	tone(620.0, 0.05, "square", -26.0, 320.0)


func hit() -> void:
	tone(200.0, 0.05, "saw", -26.0, 120.0)


func kill() -> void:
	tone(330.0, 0.08, "tri", -24.0, 520.0)


func hurt() -> void:
	tone(160.0, 0.18, "saw", -18.0, 60.0)


func level_up() -> void:
	tone(440.0, 0.10, "tri", -20.0)
	tone(660.0, 0.12, "tri", -20.0)
	tone(880.0, 0.16, "tri", -20.0)


func game_over() -> void:
	tone(300.0, 0.30, "saw", -16.0, 70.0)


func dash() -> void:
	tone(500.0, 0.12, "sine", -22.0, 900.0)


func jump() -> void:
	tone(420.0, 0.10, "square", -24.0, 760.0)


func land() -> void:
	tone(180.0, 0.06, "square", -26.0, 120.0)


func select() -> void:
	tone(880.0, 0.05, "square", -24.0)


func merge() -> void:
	tone(520.0, 0.12, "tri", -20.0, 1040.0)


func deal() -> void:
	tone(260.0, 0.05, "square", -26.0, 420.0)


func coin() -> void:
	tone(1200.0, 0.06, "square", -22.0)
	tone(1600.0, 0.08, "square", -22.0)
