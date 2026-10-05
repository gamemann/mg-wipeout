extends Node

const WoNetBridge := preload("net/wo_net_bridge.gd")
const WoServices := preload("wo_services.gd")

## The chat box and the microphone, on a client.
##
## [b]Built whether or not there is a server, and offline it echoes what you type.[/b] A box
## that only appeared on a connected client is a box nobody can test alone, and a box that
## did nothing at all reads as broken rather than as absent.
##
## [b]Nothing here decides anything about a line.[/b] What crosses the wire is a channel id
## and a string; who said it, whether they are gagged, how fast they are talking and who
## hears it are all [DotChatRouter]'s, on the server. That separation is why a client cannot
## put somebody else's name on a line.

const CHANNEL := "wo.chat"

## Typing started or stopped. The client suspends the sampler on it — see [WoClient].
signal typing_changed(typing: bool)

## The key held to talk. Physical, because the letter on it differs across layouts.
const TALK_KEY := KEY_V

var window: DotChatWindow = null
var voice: DotVoiceManager = null

var bridge: WoNetBridge = null

## Which session this client is, so a line from us can be coloured as ours.
var local_player_id: int = 0

var _talking: bool = false


func _ready() -> void:
	_build_window()
	_build_voice()


func _build_window() -> void:
	window = DotChatWindow.new()
	window.name = "ChatWindow"
	window.channels = [
		{"id": WoServices.CH_ALL, "label": "All", "colour": Color(0.93, 0.94, 0.96)},
		{"id": WoServices.CH_TEAM, "label": "Team", "colour": Color(0.55, 0.82, 0.95)},
		{"id": WoServices.CH_NEAR, "label": "Near", "colour": Color(0.82, 0.86, 0.72)},
	]
	# The rules the SERVER is going to apply, so a line is refused here rather than sent and
	# silently truncated there. The number comes from the same static the services layer
	# reads, because two copies of one limit is the duplication this family guards hardest
	# against.
	window.max_length = WoServices.chat_rules().max_length

	# [b]On its own layer, above the HUD's, and an admin's blind is the reason.[/b] Parented
	# straight to this Node the window draws in the default canvas, which is UNDER every
	# CanvasLayer — so the HUD's blind covered the chat as well, and a blinded player could
	# not read the one line saying an admin had done it, or ask why. The full-rect Control in
	# between is the HUD's own lesson: a CanvasLayer does not lay its children out.
	var layer := CanvasLayer.new()
	layer.name = "ChatLayer"
	layer.layer = 2
	add_child(layer)

	var screen := Control.new()
	screen.name = "Screen"
	screen.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	screen.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(screen)
	screen.add_child(window)

	window.submitted.connect(_on_submitted)
	window.opened.connect(func(_id: StringName) -> void: typing_changed.emit(true))
	window.closed.connect(func() -> void: typing_changed.emit(false))


func _build_voice() -> void:
	voice = DotVoiceManager.new()
	voice.name = "Voice"
	# Not the shared name: a client and a server in one process would fight over it, which
	# is what every section of this game's own suite is.
	voice.register_service = false
	voice.config = WoServices.voice_format()
	voice.positional_playback = true
	add_child(voice)


## Joins this box to a bridge, or to nothing at all.
##
## [param p_bridge] null is the offline case and is not an error: the box still opens, still
## takes a line and still shows it.
func attach(p_bridge: WoNetBridge) -> DotResult:
	bridge = p_bridge

	if bridge == null:
		window.add_text(
			"Offline. Nobody can hear you, but the box works.", Color(0.72, 0.74, 0.78)
		)
		return DotResult.success(null)

	local_player_id = bridge.local_player_id

	bridge.chat_received.connect(_on_line)
	bridge.voice_arrived.connect(_on_voice)
	bridge.hello_received.connect(func(id: int) -> void: local_player_id = id)

	# One frame out, one call. dot-voice never touches a transport — which is what lets its
	# whole path run headless — so this is the seam, and without it a client captures,
	# encodes, counts a frame and sends it nowhere.
	voice.send_fn = func(bytes: PackedByteArray) -> void:
		bridge.send_voice(bytes)

	var capturing := voice.start_capture()

	if not capturing.ok:
		# Not fatal, and said once. A machine with no microphone is a legitimate client and
		# the player can still read everything anybody says.
		DotLog.info(CHANNEL, "no microphone on this machine", {
			"why": capturing.error.message,
		})

	return DotResult.success(null)


func _on_submitted(text: String, channel_id: StringName) -> void:
	typing_changed.emit(false)

	if text.strip_edges() == "":
		return

	if bridge == null:
		# Offline, so it is echoed rather than sent. Named "you" rather than given the
		# player's name, because offline there is no identity layer to have one.
		window.add_said("you", text, Color(0.86, 0.88, 0.92))
		return

	bridge.ask_say(channel_id, text)


## One routed line, already decided. Drawn exactly as the server addressed it.
func _on_line(wire: Dictionary) -> void:
	var speaker := str(wire.get("d", ""))
	var text := str(wire.get("m", ""))
	var channel_id := StringName(str(wire.get("c", WoServices.CH_ALL)))

	if text == "":
		return

	var colour := Color(0.93, 0.94, 0.96)

	match channel_id:
		WoServices.CH_TEAM:
			colour = Color(0.55, 0.82, 0.95)
		WoServices.CH_NEAR:
			colour = Color(0.82, 0.86, 0.72)
		WoServices.CH_ADMIN:
			colour = Color(0.98, 0.72, 0.35)
		WoServices.CH_WHISPER:
			colour = Color(0.78, 0.71, 0.93)

	if speaker == "":
		window.add_text(text, colour)
		return

	window.add_said(speaker, text, colour)


func _on_voice(payload: PackedByteArray) -> void:
	if voice != null:
		var _played := voice.receive(payload)


## Something the server said to this player alone: a refusal, a rate limit, a reply.
func notice(text: String) -> void:
	if window != null:
		window.add_text(text, Color(0.98, 0.72, 0.35))


## A line the game itself wants in the box: a death, a round, a special.
func say_locally(text: String, colour: Color = Color(0.86, 0.88, 0.92)) -> void:
	if window != null:
		window.add_text(text, colour)


func is_typing() -> bool:
	return window != null and window.is_open()


## Push to talk. Held, never toggled.
##
## [b]A held key and not an event, because talking is held.[/b] An event queue is sampled
## per frame and a frame is not a tick; what matters is whether the key is down right now,
## which is one call.
func _process(_delta: float) -> void:
	if voice == null or window == null:
		return

	var wanted := Input.is_physical_key_pressed(TALK_KEY) and not window.is_open()

	if wanted == _talking:
		return

	_talking = wanted
	voice.set_talking(wanted)


func describe() -> Dictionary:
	return {
		"open": is_typing(),
		"talking": _talking,
		"lines": window.line_count() if window != null else 0,
		"voice": voice.describe() if voice != null else {},
	}
