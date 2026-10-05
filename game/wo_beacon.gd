extends Node3D

## What an administrator's `beacon` looks like here: a ring at a player's feet that sends out
## a ripple once a second, a thin column above them drawn through everything, and a ping.
##
## [b]Drawn on every client from one replicated flag.[/b] The server decides who is beaconed
## (`WoPlayer.beacon`, carried as `WoPlayerNet.net_beacon`) and nothing about the picture
## travels: the ripple's phase is each client's own, because two screens a quarter of a
## second apart in a ripple is not something anybody can see, and sending a phase would be a
## message a second per beaconed player for nothing.
##
## [b]The column is the half that matters on this map.[/b] Everybody can see everybody on a
## field of platforms in open air, so a ring alone would mostly work — until the showdown,
## where the corners are a map's width away, and the moment somebody falls behind a platform's
## edge from below. A column with no depth test says where somebody is from anywhere. The ring
## keeps its depth test: a ring showing through the deck of a platform would put the player
## on top of it when they are hanging under it.
##
## [b]No column on your own beacon.[/b] A first-person camera stands inside it, and a
## no-depth-test cylinder seen from inside is a translucent smear over the whole screen. The
## beaconed player still sees the ring at their feet and hears the ping, which is how they
## know.
##
## [b]The ping is synthesised here, because this game ships no sound at all.[/b] Every other
## game that has a beacon plays it through its dot-audio catalogue; this one has no catalogue,
## no audio addon and not one sound file, and adding a dependency to a delivered pack for one
## tone would be a bigger change than the tone. A tenth of a second of a falling sine, built
## once per marker, on an [AudioStreamPlayer3D] so it comes from where the player is — the
## whole of a beacon's job is to say WHERE, and a flat ping says only that somebody somewhere
## is beaconed.
##
## Top level, so it is placed where the player is DRAWN rather than inheriting the body's
## per-tick transform: the local player's body steps at the tick rate, and a ring that
## stepped under a smoothly moving camera would read as the ring juddering.

## Seconds between ripples, and between pings.
const PERIOD_SEC := 1.0

## How far a ripple spreads before it has faded, as a multiple of the ring.
const RIPPLE_SCALE := 3.5

## Magenta. The one colour on this map that is not the sky, the grid, the floor's hazard red
## or the cannon's orange rim — and it has to read against all four, on either side.
const COLOUR := Color(0.98, 0.22, 0.86)

## Tall enough to clear a platform seen from the showdown's corners, which are forty metres
## further up and a map's width away.
const COLUMN_HEIGHT := 30.0

## Metres the ping carries. A map's width and a little more, so a survivor in a corner hears
## a beaconed player on the field; past that a ping is noise from nowhere.
const PING_RANGE := 180.0

const PING_HZ := 880.0
const PING_SEC := 0.12
const PING_MIX_RATE := 22050

## Whether this is the beaconed player's own view. Hides the column; see above.
var local_view: bool = false:
	set(value):
		local_view = value
		if _column != null:
			_column.visible = not value

## Pings played since this marker was built. For a check: the rate is the promise.
var pings: int = 0

var _ring: MeshInstance3D = null
var _ripple: MeshInstance3D = null
var _column: MeshInstance3D = null
var _ripple_material: StandardMaterial3D = null
var _ring_material: StandardMaterial3D = null
var _voice: AudioStreamPlayer3D = null

## Seconds into the current period. Starts at the end of one, so the first advance pings:
## an admin who turns a beacon on should hear it start, not a second later.
var _phase: float = PERIOD_SEC


func _init() -> void:
	top_level = true

	_ring_material = _material(0.95, false)
	_ring = _torus(0.62, 0.8, _ring_material)
	_ring.name = "Ring"
	add_child(_ring)

	_ripple_material = _material(0.8, false)
	_ripple = _torus(0.66, 0.76, _ripple_material)
	_ripple.name = "Ripple"
	add_child(_ripple)

	var cylinder := CylinderMesh.new()
	cylinder.top_radius = 0.09
	cylinder.bottom_radius = 0.09
	cylinder.height = COLUMN_HEIGHT
	cylinder.radial_segments = 8
	cylinder.rings = 1
	_column = MeshInstance3D.new()
	_column.name = "Column"
	_column.mesh = cylinder
	_column.material_override = _material(0.5, true)
	# Starting above the head, so the column marks the player rather than hiding them.
	_column.position = Vector3(0.0, COLUMN_HEIGHT * 0.5 + 2.2, 0.0)
	_column.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_column.visible = not local_view
	add_child(_column)

	_voice = AudioStreamPlayer3D.new()
	_voice.name = "Ping"
	_voice.stream = _ping_stream()
	_voice.unit_size = 20.0
	_voice.max_distance = PING_RANGE
	_voice.position = Vector3(0.0, 1.0, 0.0)
	add_child(_voice)


## Moves the time on by [param delta], redraws, and pings when a new ripple starts. Returns
## whether it pinged.
func advance(delta: float) -> bool:
	_phase += maxf(delta, 0.0)
	var pinged := false

	if _phase >= PERIOD_SEC:
		_phase = fmod(_phase, PERIOD_SEC)
		pinged = true
		pings += 1

		if _voice.is_inside_tree():
			_voice.play()

	var t := _phase / PERIOD_SEC
	var spread := lerpf(1.0, RIPPLE_SCALE, t)
	_ripple.scale = Vector3(spread, 0.25, spread)
	_ripple_material.albedo_color.a = 0.8 * (1.0 - t) * (1.0 - t)

	# The ring breathes with the ripple rather than holding still, so a beacon seen from the
	# far end of the field — a few pixels of ring — still reads as something alive.
	_ring_material.albedo_color.a = lerpf(0.95, 0.55, t)

	return pinged


## Whether the column is being drawn. For a check.
func column_shown() -> bool:
	return _column != null and _column.visible


func _torus(inner: float, outer: float, material: StandardMaterial3D) -> MeshInstance3D:
	var torus := TorusMesh.new()
	torus.inner_radius = inner
	torus.outer_radius = outer
	torus.rings = 48
	torus.ring_segments = 8
	var mesh := MeshInstance3D.new()
	mesh.mesh = torus
	mesh.material_override = material
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Flattened to a band. A torus's tube is round, and a round tube at a player's feet
	# reads as a lifebuoy rather than a mark.
	mesh.scale = Vector3(1.0, 0.25, 1.0)
	mesh.position = Vector3(0.0, 0.06, 0.0)
	return mesh


func _material(alpha: float, through_walls: bool) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.albedo_color = Color(COLOUR.r, COLOUR.g, COLOUR.b, alpha)
	material.no_depth_test = through_walls
	return material


## A short falling sine, as sixteen-bit PCM.
##
## Falling rather than flat, and an octave under the tone a hit marker would use, so it is
## heard as "there" rather than as "I hit something" in the showdown, where both happen.
func _ping_stream() -> AudioStreamWAV:
	var frames := int(PING_SEC * PING_MIX_RATE)
	var data := PackedByteArray()
	var _sized := data.resize(frames * 2)
	var angle := 0.0

	for i in range(frames):
		var t := float(i) / float(frames)
		angle += TAU * PING_HZ * lerpf(1.0, 0.7, t) / float(PING_MIX_RATE)
		# A few milliseconds of attack so it does not click, then a quadratic decay.
		var envelope := minf(1.0, t * 30.0) * (1.0 - t) * (1.0 - t)
		data.encode_s16(i * 2, int(sin(angle) * envelope * 0.6 * 32767.0))

	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = PING_MIX_RATE
	wav.stereo = false
	wav.data = data
	return wav
