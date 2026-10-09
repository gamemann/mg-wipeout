extends Node

const WoCourse := preload("wo_course.gd")
const WoPaths := preload("wo_paths.gd")

## What this game makes a noise about, and the noise, on the client.
##
## [b]On a course the sounds are the feedback.[/b] A splash says you are going back to the
## checkpoint before the camera has caught up; the thud of an arm says it was the arm and
## not your timing; a chime at a checkpoint says the restart point moved. In a final death
## a throw and a blast behind you are the warning that works without looking.
##
## [b]A catalogue of ids and a table of stand-ins, which is the family's shape.[/b] dot-audio
## decides what is audible, how many at once, how far away it stops mattering and what loses
## to what; [method sound_catalogue] is those decisions, as a document naming paths nobody
## has produced yet. [method sound_recipes] says which synthesised voice stands in for each
## id until they are — and [DotAudioSinkGodot] consults the file before the stand-in, so
## dropping a real `.ogg` into `audio/` switches that one id over with no code change.
##
## [b]Never on a server, and never deciding anything.[/b] Every hook here is called by
## [WoClient] from something the world or the wire already said.
##
## [b]The beacon's ping is not here, deliberately[/b], as in mg-smash-copter: [WoBeacon]
## synthesises its own tone, and the day real audio ships `beacon` is the id it moves to.

const CHANNEL := "wo.audio"

## Where the real files go when somebody produces them. Rebased, because a delivered pack
## mounts this game somewhere other than `res://`.
static var SOUND_DIR := WoPaths.rebase("res://audio")

## Somebody went into the water. Positional: you hear it where they went in.
const SPLASH := &"splash"
## An obstacle threw somebody.
const KNOCK := &"knock"
## A bouncer threw somebody up.
const BOUNCE := &"bounce"
## You crossed a checkpoint. Flat: it is about you.
const CHECKPOINT := &"checkpoint"
## Somebody crossed the finish; flat and louder when it is you.
const FINISH := &"finish"
## The countdown's last seconds, and the gate dropping.
const COUNTDOWN := &"countdown"
const GATE := &"gate"
## A barrel going off.
const BARREL_BLAST := &"barrel_blast"
## Somebody else out of the final death.
const PLAYER_DOWN := &"player_down"
## You, out of the final death. Flat.
const YOU_ARE_OUT := &"you_are_out"
const ROUND_START := &"round_start"
const ROUND_END := &"round_end"
## Into the arena, and the fight starting.
const FINALE_TELEPORT := &"finale_teleport"
const FINALE_GO := &"finale_go"
## A weapon picked up off the floor.
const PICKUP := &"pickup"
## A prop thrown by somebody.
const PROP_THROWN := &"prop_thrown"
const WEAPON_SHOT := &"weapon_shot"
const WEAPON_SWING := &"weapon_swing"
const WEAPON_LAUNCH := &"weapon_launch"
const WEAPON_BEAM := &"weapon_beam"
const WEAPON_THROW := &"weapon_throw"
const UI_CLICK := &"ui_click"
const UI_DENY := &"ui_deny"

## The course's machinery: an arm or a hammer going past, a ram at full reach, a tile about to
## drop. Synthesised here (see "The machinery") and derived on the client from the course
## itself (see [method present_machinery]); nothing about them is sent.
const MACHINE_WHOOSH := &"machine_whoosh"
const MACHINE_RAM := &"machine_ram"
const MACHINE_TILE := &"machine_tile"

var manager: DotAudioManager = null


static func ids() -> Array[StringName]:
	return [
		SPLASH, KNOCK, BOUNCE, CHECKPOINT, FINISH, COUNTDOWN, GATE,
		BARREL_BLAST, PLAYER_DOWN, YOU_ARE_OUT, ROUND_START, ROUND_END,
		FINALE_TELEPORT, FINALE_GO, PICKUP, PROP_THROWN,
		WEAPON_SHOT, WEAPON_SWING, WEAPON_LAUNCH, WEAPON_BEAM, WEAPON_THROW,
		UI_CLICK, UI_DENY,
		MACHINE_WHOOSH, MACHINE_RAM, MACHINE_TILE,
	]


## Every decision about every noise. The distances are a course's: the longest is two
## hundred metres, and a splash further back than eighty is not about you.
static func sound_catalogue() -> DotAudioCatalogue:
	var c := DotAudioCatalogue.new()

	c.add(_placed(SPLASH, 80.0, 10.0, 4, 60, 0.85, 1.15))
	var knock := _placed(KNOCK, 60.0, 8.0, 4, 65, 0.85, 1.1)
	knock.cooldown_ms = 120
	c.add(knock)
	c.add(_placed(BOUNCE, 50.0, 8.0, 3, 50, 0.95, 1.1))
	c.add(_placed(BARREL_BLAST, 120.0, 18.0, 3, 88, 0.9, 1.1))
	c.add(_placed(PLAYER_DOWN, 80.0, 12.0, 3, 65, 0.95, 1.05))
	c.add(_placed(PROP_THROWN, 40.0, 8.0, 3, 55, 0.9, 1.1))
	c.add(_placed(PICKUP, 30.0, 6.0, 2, 50, 1.0, 1.0))

	c.add(_flat(CHECKPOINT, &"UI", 1, 70))
	c.add(_flat(FINISH, &"UI", 2, 80))
	var beep := _flat(COUNTDOWN, &"UI", 1, 70)
	beep.cooldown_ms = 400
	c.add(beep)
	c.add(_flat(GATE, &"UI", 1, 85))
	c.add(_flat(YOU_ARE_OUT, &"SFX", 1, 100))
	c.add(_flat(ROUND_START, &"UI", 1, 80))
	c.add(_flat(ROUND_END, &"UI", 1, 80))
	c.add(_flat(FINALE_TELEPORT, &"UI", 1, 85))
	c.add(_flat(FINALE_GO, &"UI", 1, 85))

	var shot := _placed(WEAPON_SHOT, 110.0, 14.0, 3, 80, 0.94, 1.06)
	shot.tags = [&"weapon"]
	c.add(shot)
	var swing := _placed(WEAPON_SWING, 30.0, 6.0, 2, 55, 0.9, 1.1)
	swing.tags = [&"weapon"]
	c.add(swing)
	var launch := _placed(WEAPON_LAUNCH, 140.0, 16.0, 2, 82, 0.95, 1.05)
	launch.tags = [&"weapon"]
	c.add(launch)
	var beam := _placed(WEAPON_BEAM, 90.0, 12.0, 1, 75, 1.0, 1.0)
	beam.cooldown_ms = 180
	beam.tags = [&"weapon"]
	c.add(beam)
	var throw := _placed(WEAPON_THROW, 40.0, 8.0, 2, 55, 0.95, 1.05)
	throw.tags = [&"weapon"]
	c.add(throw)

	# Short reach and a low priority: a course has a dozen machines going at once and only
	# the ones next to you are worth a voice. The whoosh's concurrency is the one that
	# matters — a four-armed spinner beside a pair of hammers is six passes a second.
	c.add(_placed(MACHINE_WHOOSH, 22.0, 5.0, 4, 45, 0.9, 1.12))
	c.add(_placed(MACHINE_RAM, 35.0, 7.0, 3, 50, 0.92, 1.08))
	c.add(_placed(MACHINE_TILE, 18.0, 4.0, 3, 48, 0.95, 1.05))

	var click := _flat(UI_CLICK, &"UI", 2, 60)
	click.cooldown_ms = 60
	c.add(click)
	var deny := _flat(UI_DENY, &"UI", 1, 60)
	deny.cooldown_ms = 250
	c.add(deny)

	return c


## Which synthesised voice stands in for each id until a file exists.
static func sound_recipes() -> Dictionary:
	return {
		SPLASH: DotAudioSynth.Voice.DIE,
		KNOCK: DotAudioSynth.Voice.IMPACT,
		BOUNCE: DotAudioSynth.Voice.SPAWN,
		CHECKPOINT: DotAudioSynth.Voice.PICKUP,
		FINISH: DotAudioSynth.Voice.SPAWN,
		COUNTDOWN: DotAudioSynth.Voice.BLIP,
		GATE: DotAudioSynth.Voice.SHOT_HEAVY,
		BARREL_BLAST: DotAudioSynth.Voice.BOOM,
		PLAYER_DOWN: DotAudioSynth.Voice.HURT,
		YOU_ARE_OUT: DotAudioSynth.Voice.DIE,
		ROUND_START: DotAudioSynth.Voice.SPAWN,
		ROUND_END: DotAudioSynth.Voice.PICKUP,
		FINALE_TELEPORT: DotAudioSynth.Voice.SPAWN,
		FINALE_GO: DotAudioSynth.Voice.BLIP,
		PICKUP: DotAudioSynth.Voice.PICKUP,
		PROP_THROWN: DotAudioSynth.Voice.CLICK,
		WEAPON_SHOT: DotAudioSynth.Voice.SHOT,
		WEAPON_SWING: DotAudioSynth.Voice.STEP,
		WEAPON_LAUNCH: DotAudioSynth.Voice.SHOT_HEAVY,
		WEAPON_BEAM: DotAudioSynth.Voice.SHOT_TIGHT,
		WEAPON_THROW: DotAudioSynth.Voice.CLICK,
		UI_CLICK: DotAudioSynth.Voice.CLICK,
		UI_DENY: DotAudioSynth.Voice.DENY,
	}


static func weapon_sound(kind: int) -> StringName:
	match kind:
		ZeeWeaponNet.KIND_SHOT:
			return WEAPON_SHOT
		ZeeWeaponNet.KIND_SWING:
			return WEAPON_SWING
		ZeeWeaponNet.KIND_SPAWN:
			return WEAPON_LAUNCH
		ZeeWeaponNet.KIND_BEAM:
			return WEAPON_BEAM
		ZeeWeaponNet.KIND_THROW:
			return WEAPON_THROW
		_:
			return &""


static func _placed(
	id: StringName,
	max_distance: float,
	unit_size: float,
	concurrent: int,
	priority: int,
	pitch_min: float,
	pitch_max: float
) -> DotAudioDef:
	var def := DotAudioDef.new()
	def.id = id
	def.path = "%s/%s.ogg" % [SOUND_DIR, String(id)]
	def.kind = DotAudioDef.Kind.POSITIONAL_3D
	def.bus = &"SFX"
	def.max_distance = max_distance
	def.unit_size = unit_size
	def.max_concurrent = concurrent
	def.priority = priority
	def.pitch_min = pitch_min
	def.pitch_max = pitch_max
	return def


static func _flat(id: StringName, bus: StringName, concurrent: int, priority: int) -> DotAudioDef:
	var def := DotAudioDef.new()
	def.id = id
	def.path = "%s/%s.ogg" % [SOUND_DIR, String(id)]
	def.bus = bus
	def.max_concurrent = concurrent
	def.priority = priority
	return def


# --- Building ---------------------------------------------------------------

func setup() -> DotResult:
	manager = DotAudioManager.new()
	manager.name = "Audio"
	manager.catalogue = sound_catalogue()
	manager.mixer = DotAudioMixer.new()
	# Not published: a client and a server in one process, which every suite here is, would
	# otherwise fight over one registry name — and nothing looks this up by name anyway.
	manager.register_as_service = false
	# A barrage, a collapse and a firefight at once is the busiest this game gets.
	manager.voices = 24
	add_child(manager)

	var ready_now := manager.setup()

	if not ready_now.ok:
		return ready_now.wrap("wipeout audio")

	# Only on a real sink: the manager has already decided whether there is a device, and a
	# headless process has nothing to bake for.
	var godot_sink := manager.sink as DotAudioSinkGodot

	if godot_sink != null:
		godot_sink.bank = DotAudioSynth.bank(manager.catalogue, sound_recipes())
		_bake_machinery(godot_sink.bank, manager.catalogue)
		# INFO, once: the answer to "why does it sound like that" is in this line.
		DotLog.info(CHANNEL, "no audio files; synthesised stand-ins are in use", {
			"ids": sound_recipes().size(), "dir": SOUND_DIR,
		})

	return DotResult.success(null)


## Where the ears are, once a frame. The camera, which is the spectator's camera too.
func listen_from(at: Vector3) -> void:
	if manager != null:
		manager.listener_position = at


func on_splash(at: Vector3) -> bool:
	return _at(SPLASH, at)


func on_knock(at: Vector3) -> bool:
	return _at(KNOCK, at)


func on_bounce(at: Vector3) -> bool:
	return _at(BOUNCE, at)


func on_checkpoint() -> bool:
	return _flat_play(CHECKPOINT)


func on_finish(mine: bool) -> bool:
	return _flat_play(FINISH) if mine else false


func on_countdown() -> bool:
	return _flat_play(COUNTDOWN)


func on_gate() -> bool:
	return _flat_play(GATE)


func on_blast(at: Vector3) -> bool:
	return _at(BARREL_BLAST, at)


func on_death(at: Vector3, mine: bool) -> bool:
	if mine:
		return _flat_play(YOU_ARE_OUT)

	return _at(PLAYER_DOWN, at)


func on_round(began: bool) -> bool:
	return _flat_play(ROUND_START if began else ROUND_END)


func on_handover() -> bool:
	return _flat_play(FINALE_TELEPORT)


func on_finale() -> bool:
	return _flat_play(FINALE_GO)


func on_pickup(at: Vector3) -> bool:
	return _at(PICKUP, at)


func on_weapon(at: Vector3, kind: int) -> bool:
	var id := weapon_sound(kind)
	return _at(id, at) if id != &"" else false


func click() -> bool:
	return _flat_play(UI_CLICK)


func deny() -> bool:
	return _flat_play(UI_DENY)


func _at(id: StringName, at: Vector3, volume: float = 1.0) -> bool:
	return manager != null and manager.play_at(id, at, volume) != 0


func _flat_play(id: StringName) -> bool:
	return manager != null and manager.play(id) != 0


# --- The machinery, heard -----------------------------------------------------
#
# [b]Derived once a frame from the course, and never sent[/b] — Decision 1 again. Where an arm
# is at any moment is a formula the client already evaluates to draw it, so "an arm just went
# past you" is that formula at this frame's time against the last frame's. The mg-smash-copter
# creak is the same idea. Only the machines near the ears are asked anything: the catalogue's
# reach would cull the rest anyway, and a course is a hundred metres of them.

## How near the ears a machine has to be for this frame to ask it anything, in metres.
const MACHINE_EARSHOT := 30.0

## How far outside an arm's own length it is still heard sweeping past, in metres.
const WHOOSH_REACH := 7.0

## The course time [method present_machinery] last looked at, or a negative before the first.
var _machine_seconds: float = -1.0


## Plays what the course's machines did between the last frame and [param seconds], heard
## from [param listener]. Returns how many sounds it started. [param course] is a `WoCourse`.
##
## [b]A jump in time is not a sweep[/b]: a new stage, a reconnect or a paused frame skips more
## than [code]0.25[/code] s, and every arm on the course would otherwise be heard passing at
## once. The first frame after one only remembers the time.
func present_machinery(course: Node, seconds: float, listener: Vector3) -> int:
	var before := _machine_seconds
	_machine_seconds = seconds

	if course == null or manager == null or before < 0.0 or seconds <= before or seconds - before > 0.25:
		return 0

	var started := 0
	var pieces: Array = course.get(&"pieces")

	for piece: Dictionary in pieces:
		var spec: Dictionary = piece.get("spec", {})

		match str(piece.get("kind", "")):
			"spinner":
				started += _hear_spinner(piece, spec, before, seconds, listener)
			"pendulum":
				started += _hear_pendulum(spec, before, seconds, listener)
			"pusher":
				started += _hear_pusher(spec, before, seconds, listener)
			"tiles":
				started += _hear_tiles(piece, spec, before, seconds, listener)

	return started


## Forgets the last frame's time, so the next one is a first frame. For a new stage.
func reset_machinery() -> void:
	_machine_seconds = -1.0


## An arm crossing the listener's bearing from the hub, on the side the listener is.
func _hear_spinner(piece: Dictionary, spec: Dictionary, before: float, now: float, listener: Vector3) -> int:
	var root: Node3D = piece.get("node")
	if root == null:
		return 0

	var length := float(spec["arm_length"])
	var hub := root.transform * Vector3(0.0, float(spec.get("arm_height", 1.0)), 0.0)
	var to := listener - hub
	to.y = 0.0

	if to.length() > length + WHOOSH_REACH or to.length() < 0.01:
		return 0

	var count := maxi(int(spec.get("arms", 1)), 1)
	var started := 0

	for arm in range(count):
		var offset := TAU * float(arm) / float(count)
		var was := _arm_direction(root, spec, before, offset)
		var is_now := _arm_direction(root, spec, now, offset)

		# Which side of the bearing, as a bool and not `signf`: an arm exactly on the bearing
		# is a zero, and `signf(0)` differs from both signs, so a frame starting there was a
		# pass that had not happened.
		if (was.cross(to).y > 0.0) != (is_now.cross(to).y > 0.0) and is_now.dot(to) > 0.0:
			var at := hub + to.normalized() * minf(to.length(), length)
			if _at(MACHINE_WHOOSH, at):
				started += 1

	return started


static func _arm_direction(root: Node3D, spec: Dictionary, t: float, offset: float) -> Vector3:
	var heading := Basis(Vector3.UP, WoCourse.spinner_angle(spec, t) + offset) * Vector3.RIGHT
	var out := root.transform.basis * heading
	out.y = 0.0
	return out.normalized()


## A hammer through the bottom of its swing, which is where it is fastest and lowest.
func _hear_pendulum(spec: Dictionary, before: float, now: float, listener: Vector3) -> int:
	var frame := Transform3D(Basis(Vector3.UP, deg_to_rad(float(spec.get("yaw", 0.0)))), spec["pivot"])
	var bottom := frame * Vector3(0.0, -float(spec["length"]), 0.0)

	if bottom.distance_to(listener) > MACHINE_EARSHOT:
		return 0

	if signf(WoCourse.pendulum_angle(spec, before)) == signf(WoCourse.pendulum_angle(spec, now)):
		return 0

	return 1 if _at(MACHINE_WHOOSH, bottom) else 0


## A ram arriving at full reach: the moment it would hit somebody, and the one to hear coming.
func _hear_pusher(spec: Dictionary, before: float, now: float, listener: Vector3) -> int:
	if WoCourse.pusher_extension(spec, before) >= 0.999 or WoCourse.pusher_extension(spec, now) < 0.999:
		return 0

	var at := WoCourse.pusher_transform(spec, now).origin

	if at.distance_to(listener) > MACHINE_EARSHOT:
		return 0

	return 1 if _at(MACHINE_RAM, at) else 0


## A tile starting its warning: the rattle that goes with the red, from that tile.
func _hear_tiles(piece: Dictionary, spec: Dictionary, before: float, now: float, listener: Vector3) -> int:
	var root: Node3D = piece.get("node")
	if root == null or root.global_position.distance_to(listener) > MACHINE_EARSHOT + 10.0:
		return 0

	var started := 0
	var index := 0

	for child in root.get_children():
		var tile := child as Node3D
		if tile == null:
			continue

		if WoCourse.tile_warning(spec, index, before) <= 0.0 and WoCourse.tile_warning(spec, index, now) > 0.0:
			var at := root.transform * (tile.get_meta(&"rest", Vector3.ZERO) as Vector3)
			if at.distance_to(listener) <= MACHINE_EARSHOT and _at(MACHINE_TILE, at):
				started += 1

		index += 1

	return started


# --- The machinery, synthesised -----------------------------------------------
#
# dot-audio's voices are one swept tone with noise; a hammer going past is air moving, which
# is filtered noise rising and falling, so these are baked here into the same bank under the
# id and the path a real file would have (mg-deathrun's way). A real `.ogg` still wins.

const RATE := 22050


static func _bake_machinery(bank: Dictionary, catalogue: DotAudioCatalogue) -> void:
	var made := {MACHINE_WHOOSH: _whoosh(), MACHINE_RAM: _ram(), MACHINE_TILE: _rattle()}

	for id: StringName in made:
		bank[id] = made[id]
		var def := catalogue.find(id)

		if def != null and not def.path.is_empty():
			bank[def.path] = made[id]


static func _wav(samples: PackedFloat32Array) -> AudioStreamWAV:
	var data := PackedByteArray()
	data.resize(samples.size() * 2)

	for i in samples.size():
		data.encode_s16(i * 2, int(clampf(samples[i], -1.0, 1.0) * 32767.0))

	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = RATE
	wav.data = data
	return wav


static func _buffer(seconds: float) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(int(RATE * seconds))
	return out


## Something big going past: noise through a low-pass that opens and closes, swelling to the
## middle. The filter's opening is the pass; without it, it is a hiss.
static func _whoosh() -> AudioStreamWAV:
	var out := _buffer(0.55)
	var rng := RandomNumberGenerator.new()
	rng.seed = 31
	var low := 0.0

	for i in out.size():
		var t := float(i) / RATE
		var u := t / 0.55
		var swell := sin(PI * u)
		low = lerpf(low, rng.randf_range(-1.0, 1.0), lerpf(0.04, 0.22, swell))
		out[i] = low * 2.2 * swell * swell

	return _wav(out)


## A ram arriving: a padded thump and the clack of it reaching its stop.
static func _ram() -> AudioStreamWAV:
	var out := _buffer(0.45)
	var rng := RandomNumberGenerator.new()
	rng.seed = 32

	for i in out.size():
		var t := float(i) / RATE
		var thump := sin(TAU * lerpf(95.0, 55.0, minf(t / 0.2, 1.0)) * t) * exp(-t * 11.0) * 0.85
		var clack := rng.randf_range(-1.0, 1.0) * exp(-t * 70.0) * 0.35
		out[i] = thump + clack

	return _wav(out)


## A tile working loose: a dry rattle at 18 Hz for as long as the red warning lasts.
static func _rattle() -> AudioStreamWAV:
	var seconds := 0.6
	var out := _buffer(seconds)
	var rng := RandomNumberGenerator.new()
	rng.seed = 33
	var mid := 0.0

	for i in out.size():
		var t := float(i) / RATE
		mid = lerpf(mid, rng.randf_range(-1.0, 1.0), 0.45)
		var chatter := maxf(0.0, sin(TAU * 18.0 * t)) ** 3.0
		var swell := minf(t / 0.08, 1.0) * clampf((seconds - t) / 0.12, 0.0, 1.0)
		out[i] = mid * 0.8 * chatter * swell

	return _wav(out)


func describe() -> Dictionary:
	return manager.describe() if manager != null else {}
