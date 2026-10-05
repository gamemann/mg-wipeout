extends CanvasLayer

const WoGame := preload("wo_game.gd")
const WoPlayer := preload("wo_player.gd")

## The clock, where you are on the course, and in a final death how much you have left.
##
## [b]How far along you are is the bar along the bottom, and it is the number a player
## cannot read off the world.[/b] A course is long and mostly behind you; the checkpoints
## crossed out of the course's total says whether a fall now costs ten seconds or a minute,
## and the finished count says whether the course is about to close.
##
## [b]Health only in a final death.[/b] Nothing on a course can hurt you — a fall is a
## restart, a knock is a flight — so a health number there would be a number that never
## moves, and the one thing a player learns from a number that never moves is to ignore it.

# No `const CHANNEL`. This draws numbers from state somebody else owns and has nothing an
# operator would act on; the round, the finishes and the deaths are logged by [WoGame],
# which is where the decisions are. A channel declared and never used is a file that meant
# to say something and does not.

var game: WoGame = null
var player: WoPlayer = null

var _clock: Label = null
var _phase: Label = null
var _health: Label = null
var _field: Label = null
var _special: Label = null
var _shout: Label = null

## What a player who is out is looking at, and the keys that change it. Empty while playing.
var watching_label: Label = null
var _tilt_back: ColorRect = null
var _tilt_fill: ColorRect = null
var _root: Control = null

## Seconds left of the big shouted line in the middle of the screen.
var _shout_for: float = 0.0

## An administrator's `blind`, over the world and under the HUD's numbers.
##
## [b]Under the numbers, on purpose.[/b] A blind takes the game away, not the player's
## bearings: the clock, the phase and their own health still say the round is going on and
## that they are in it, which is what makes it read as "an admin did this" rather than as a
## client that stopped drawing.
##
## [b]But not under the progress bar, which a blind hides.[/b] The bar says how much of the
## course is behind them, which is a thing their eyes would have told them.
##
## Black rather than white. A white screen at full brightness is a thing a player can be
## hurt by in a dark room, and taking the picture away is the whole of the point.
var blind_overlay: ColorRect = null

## Seconds a blind takes to come down and to lift. Short, so it is unmistakably on, and not
## instant, so it reads as something done to the screen rather than a frame dropped.
const BLIND_FADE_SEC := 0.25

const BLIND_COLOUR := Color(0.01, 0.01, 0.015)


func bind(p_game: WoGame, p_player: WoPlayer) -> void:
	game = p_game
	player = p_player

	if _root == null:
		_build()


func _build() -> void:
	# [b]A full-rect Control between the CanvasLayer and the labels, and the first render of
	# game-buses-from-hell is why.[/b] A CanvasLayer is not a Control and does not lay its
	# children out, so anchors on a Label parented straight to one resolve against nothing:
	# every label lands in the top-left corner on top of the others, and the only one
	# visible is whichever drew last, clipped in half by the edge of the screen. It reads as
	# the HUD being half-written.
	_root = Control.new()
	_root.name = "Screen"
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	# First, so every widget added below draws over it. Full rect on `_root`, which is full
	# rect on a CanvasLayer — so the whole viewport, with no safe-area inset between them to
	# leave a frame of the world showing round the edge, which is what game-arena's first
	# render of its own blind found. See [member blind_overlay].
	blind_overlay = ColorRect.new()
	blind_overlay.name = "Blind"
	blind_overlay.color = BLIND_COLOUR
	blind_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	blind_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	blind_overlay.modulate.a = 0.0
	blind_overlay.visible = false
	_root.add_child(blind_overlay)

	var size := 22

	_clock = _label(size + 14)
	_clock.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	_clock.offset_top = 16.0
	_clock.offset_bottom = 72.0
	_clock.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

	_phase = _label(size)
	_phase.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	_phase.offset_top = 74.0
	_phase.offset_bottom = 108.0
	_phase.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

	_special = _label(size)
	_special.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	_special.offset_top = 110.0
	_special.offset_bottom = 144.0
	_special.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_special.add_theme_color_override("font_color", Color(0.98, 0.78, 0.33))

	_shout = _label(size + 20)
	_shout.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_shout.offset_top = 190.0
	_shout.offset_bottom = 260.0
	_shout.offset_left = -520.0
	_shout.offset_right = 520.0
	_shout.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_shout.add_theme_color_override("font_color", Color(0.99, 0.86, 0.40))

	# [b]Above the chat box, because the chat box also draws itself bottom-left.[/b] The
	# first render had the health number and the first line of chat in the same forty pixels,
	# one on top of the other — which is exactly the shape of the bug game-buses-from-hell
	# shipped with four HUD labels, and is invisible to a headless suite because a headless
	# viewport is 64 x 64 and nothing there can overlap anything.
	_health = _label(size + 16)
	_health.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	_health.offset_left = 30.0
	_health.offset_right = 300.0
	_health.offset_top = -210.0
	_health.offset_bottom = -150.0

	_field = _label(size)
	_field.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	_field.offset_left = -400.0
	_field.offset_right = -30.0
	_field.offset_top = -80.0
	_field.offset_bottom = -26.0
	_field.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT

	# Bottom middle, above where the chat box's input line opens, and under nothing else:
	# the health number is bottom-left and the field bottom-right, and a player who is out
	# has no use for either.
	watching_label = _label(size)
	watching_label.name = "Watching"
	watching_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	watching_label.offset_left = -520.0
	watching_label.offset_right = 520.0
	watching_label.offset_top = -140.0
	watching_label.offset_bottom = -104.0
	watching_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	watching_label.add_theme_color_override("font_color", Color(0.80, 0.90, 1.0))

	_build_tilt()

	# A dot rather than a cross. For the whole first half there is nothing to aim at, and in
	# the second half every weapon in the pack has its own spread — so what a player needs is
	# "the point I am looking at", which is one pixel.
	var dot := ColorRect.new()
	dot.name = "Crosshair"
	dot.color = Color(1.0, 1.0, 1.0, 0.75)
	dot.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	dot.offset_left = -3.0
	dot.offset_top = -3.0
	dot.offset_right = 3.0
	dot.offset_bottom = 3.0
	dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(dot)


## The progress bar: how much of the course is behind you.
func _build_tilt() -> void:
	_tilt_back = ColorRect.new()
	_tilt_back.name = "TiltBack"
	_tilt_back.color = Color(0.0, 0.0, 0.0, 0.42)
	_tilt_back.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	_tilt_back.offset_left = -150.0
	_tilt_back.offset_right = 150.0
	_tilt_back.offset_top = -46.0
	_tilt_back.offset_bottom = -30.0
	_tilt_back.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_tilt_back)

	_tilt_fill = ColorRect.new()
	_tilt_fill.name = "TiltFill"
	_tilt_fill.color = Color(0.45, 0.82, 0.48, 0.9)
	_tilt_fill.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	_tilt_fill.offset_left = -150.0
	_tilt_fill.offset_right = -150.0
	_tilt_fill.offset_top = -46.0
	_tilt_fill.offset_bottom = -30.0
	_tilt_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_tilt_fill)


func _label(size: int) -> Label:
	var label := Label.new()
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", Color(1, 1, 1))
	# An outline rather than a panel behind it. This HUD is drawn over a bright sky, dark
	# water and a grey deck in the same frame; white is unreadable over one and black
	# over another, and an outline is readable over all three and costs nothing.
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	label.add_theme_constant_override("outline_size", 6)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(label)
	return label


## The spectator line, or an empty string to take it away. See [WoSpectate.line_for].
func set_watching(text: String) -> void:
	if watching_label != null:
		watching_label.text = text


## One line in the middle of the screen, for a few seconds. What a special announces itself
## with, and what a round ending says.
func shout(text: String, seconds: float = 3.5) -> void:
	if _shout == null:
		return

	_shout.text = text
	_shout_for = seconds


func _process(delta: float) -> void:
	present_blind(delta)

	if game == null or game.config == null or _root == null:
		return

	var left := game.seconds_left()
	_clock.text = "%d:%02d" % [int(left) / 60, int(left) % 60]
	_phase.text = _phase_line()
	_special.text = str((game.stage.doc if game.stage != null else {}).get("name", ""))

	var fighting := game.phase == WoGame.Phase.FINALE or game.phase == WoGame.Phase.HANDOVER

	if player != null and player.health != null and fighting and not player.watching:
		_health.text = "%d" % int(round(player.health.health))
		var hurt := player.health.health <= player.health.max_health * 0.25
		_health.add_theme_color_override(
			"font_color", Color(1.0, 0.35, 0.3) if hurt else Color(1, 1, 1)
		)
	else:
		_health.text = ""

	if fighting:
		_field.text = "%d still up" % game.alive_count()
	else:
		_field.text = "%d across of %d" % [game.finished_count(), game.players.size()]

	_draw_progress()

	if _shout_for > 0.0:
		_shout_for -= delta

		if _shout_for <= 0.0:
			_shout.text = ""


func present_blind(delta: float) -> void:
	if blind_overlay == null:
		return

	var want := 1.0 if is_blind() else 0.0
	blind_overlay.modulate.a = move_toward(
		blind_overlay.modulate.a, want, maxf(delta, 0.0) / BLIND_FADE_SEC
	)
	blind_overlay.visible = blind_overlay.modulate.a > 0.0


## Whether the player this HUD follows is blinded.
func is_blind() -> bool:
	return player != null and is_instance_valid(player) and player.blinded


func _phase_line() -> String:
	if not game.sides_are_playable():
		return "waiting for players"

	match game.phase:
		WoGame.Phase.COUNTDOWN:
			return "get ready"
		WoGame.Phase.COURSE:
			if player != null and player.finished:
				return "finished #%d in %.1f s" % [player.place, player.finish_seconds]
			return "%.1f s" % game.course_elapsed
		WoGame.Phase.HANDOVER:
			if player != null and player.watching:
				return "the final death — you are watching"
			return "the final death — grab something"
		WoGame.Phase.FINALE:
			if player != null and player.watching:
				return "watching the final death"
			if player != null and player.grab != null and player.grab.is_carrying():
				return "carrying — click to throw, E to drop"
			return "last one standing — E picks things up"
		_:
			return "between rounds"


## The bar along the bottom: the checkpoints crossed out of the course's total, then full and
## gold once across. Hidden in an arena and behind an admin's blind.
func _draw_progress() -> void:
	if _tilt_fill == null or _tilt_back == null:
		return

	var on_course := game.stage != null and game.stage.is_course() and game.phase != WoGame.Phase.IDLE

	if player == null or not on_course or is_blind():
		_tilt_back.visible = false
		_tilt_fill.visible = false
		return

	_tilt_back.visible = true
	_tilt_fill.visible = true

	# The finish counts as the last step, so the bar is full only across the line.
	var steps := game.stage.checkpoint_count() + 1
	var done := steps if player.finished else player.checkpoint + 1
	var fraction := clampf(float(done) / float(maxi(steps, 1)), 0.0, 1.0)
	_tilt_fill.offset_right = -150.0 + 300.0 * fraction
	_tilt_fill.color = Color(0.98, 0.80, 0.30, 0.95) if player.finished \
		else Color(0.40, 0.72, 0.95, 0.9)
