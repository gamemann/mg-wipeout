extends CharacterBody3D

const WoBeacon := preload("wo_beacon.gd")
const WoConfig := preload("wo_config.gd")
const WoController := preload("wo_controller.gd")
const WoCourse := preload("wo_course.gd")
const WoFigure := preload("wo_figure.gd")
const WoAvatars := preload("wo_avatars.gd")

## One person: how they move, what the course does to them, how far along it they are, and
## what they are holding.
##
## [b]Everything the course does to a player happens inside their own tick[/b] — see
## [WoController] — and is a function of their state and the tick, so a connected client
## predicting itself gets the same carry, the same bounce and the same knock the server does.
## What happens to a player that is NOT a function of the tick (falling in, a checkpoint, the
## finish, a weapon picked up) is the server's alone and arrives in a snapshot or an event.

const CHANNEL := "wo.player"

## Metres above a player's feet that their eyes are.
##
## Here rather than on the client, because it is where a shot leaves from as well as where
## the camera is, and the two being one number is what stops a player hitting what they are
## not looking at.
const EYE_HEIGHT := 1.6

## Somebody shot them, threw something at them, or they fell out of the arena.
signal died(by: StringName)

@export var player_id: StringName = &"local"
@export var display_name: String = "Player"

## What this player looks like, as a dot-user-avatar document; null is the stock person.
var avatar: DotAvatar = null

## Whether a command is sampled from the input devices each tick. The person at the keyboard.
@export var samples_input: bool = false

## Whether this player is driven by the game rather than by a person.
##
## [b]Separate from [member samples_input], and conflating the two is a bug waiting for
## netcode.[/b] Every remote player also samples nothing; what makes a bot a bot is that
## something here decides for them.
@export var is_bot: bool = false

var config: WoConfig = null

var controller: WoController = null
var sampler: DotFpsSampler = null
var health: DotHealth = null

## The weapons, once the final death has handed some out or this player picked one up.
var weapons: ZeeWeaponRig = null

## What they are carrying in the final death, if anything. See [WoGame._advance_grabs].
var grab: DotGravGun = null

## The course (or the arena) they are on. Set by [WoGame]; read inside the tick.
var stage: WoCourse = null

## Which side they are on: a team id, or with no teams a side of their own. See [WoGame].
var team: int = 0

## The entity id dot-combat and dot-entity know them by.
var entity_id: int = 0

## How many times [method place_at] has put them somewhere. Replicated, so a watcher's
## interpolator draws a teleport as one instead of as a flight across the course.
var warps: int = 0

## The last checkpoint they crossed, or -1 for none. Server side; replicated.
var checkpoint: int = -1

## Whether they have crossed the finish this round. Server side; replicated.
var finished: bool = false

## Where they finished, 1 for first. 0 until they do.
var place: int = 0

## Seconds into the course they crossed the finish.
var finish_seconds: float = 0.0

## How many times they have fallen in this round.
var falls: int = 0

## Whether they are watching rather than playing: in the gallery during a final death they
## did not reach. Not dead — nothing can hurt them — and not counted on any side.
var watching: bool = false

## Which weapon slot they have asked for, from this game's own input message.
var wanted_slot: int = 0

## Whether they are asking to pick up (or put down) a prop, from the same message.
var wants_grab: bool = false

## The knock limits, `[minimum, maximum, lift]` in m/s, from the configuration.
var knock_limits := Vector3(8.0, 22.0, 5.5)

## How many times an obstacle has thrown them this round. Counted on both ends; a client's
## copy is its own prediction and only feeds what it draws.
var knocks: int = 0

## The last tick an obstacle threw them on, so one contact is one knock and not one per
## tick for as long as the capsule is inside the arm.
var _knocked_tick: int = -1000

## How hard the last knock threw this player, in m/s, and whether it was lightning: what
## the server charges in health when it notices the knock. See [member WoConfig.knock_damage_per_speed].
## Points this match: finishes and round wins. Not reset by a round. See [member WoConfig.finish_points].
var points: int = 0

## Round trip to the server in ms, as the server last heard it; -1 unknown. For the Tab board.
var ping_ms: int = -1

var last_knock_speed: float = 0.0
var last_knock_struck: bool = false

## An administrator's `blind`: this player's own screen is blacked out. Owner-only on the wire.
var blinded: bool = false

## An administrator's `beacon`: a ring, a column and a ping every client draws.
var beacon: bool = false

var beacon_marker: WoBeacon = null

## What other people see this player as. Client side.
var figure: WoFigure = null

# --- What a watcher draws in their hand. Client side --------------------------
#
# A player this process SIMULATES (an offline stand-in, or yourself in third person) is read
# off their own rig. One it only MIRRORS has no rig here at all — the server owns it — so it
# is drawn from two things the wire already carries: the weapons the server ANNOUNCED it
# dealt them (`WoEvents.Kind.ARMED`, one per weapon) and the slot the snapshot says is in
# hand. A slot alone names no weapon, because the pack puts several weapons in each slot;
# the dealt list alone does not say which of two is out.

## Whether [member mirror_slot] and the rest are written from a snapshot (`WoPlayerNet`).
var mirrored: bool = false

## The weapons the server said it dealt them, in the order it dealt them.
var dealt: Array[StringName] = []

## The round [member dealt] belongs to: a deal for a new round starts a new list.
var dealt_round: int = -1

var mirror_slot: int = 0
var mirror_switching: bool = false

## Uses the snapshot reported since the figure last drew them, and their kind.
var mirror_fired: int = 0
var mirror_fire_kind: int = 0

## The rig's own counter as the figure last saw it, for a simulated player.
var _seen_fire_seq: int = -1

## Every pack weapon's slot, by id. Built once per process; a slot does not depend on the
## damage table a game passes the pack.
static var _slots: Dictionary = {}

var tick_rate: int = 64:
	set(value):
		tick_rate = value
		if controller != null:
			controller.tick_rate = value


## The key [DotWeaponPlayerBridge] identifies this carrier by. Duck-typed: see mg-smash-
## copter's note, where a misspelling made every shot come from entity zero.
var player_key: String:
	get:
		return String(player_id)


func _ready() -> void:
	controller = WoController.new()
	controller.name = "Controller"
	controller.tick_rate = tick_rate
	# EXTERNAL even offline: the world owns the tick, so "pose the course, move, then let the
	# course act on the player" is explicit, and it is the shape a dedicated server needs.
	controller.drive = DotFpsController.Drive.EXTERNAL
	controller.tunables = tunables_for(config)
	controller.admin_abilities = true
	controller.before_fn = _before_tick
	controller.after_fn = _after_tick
	add_child(controller)

	if config != null:
		knock_limits = Vector3(config.knock_min_speed, config.knock_max_speed, config.knock_lift)

	if samples_input:
		sampler = DotFpsSampler.new(controller.tunables)
		register_actions(sampler)


## How a player moves.
##
## [b]Static, and it takes the config,[/b] for mg-smash-copter's reason: a connected client
## builds a sampler before it has a player, and a sampler built from different tunables than
## the controller it feeds is input clamped differently from the simulation that consumes it.
static func tunables_for(config: WoConfig) -> DotFpsTunables:
	var t := DotFpsTunables.new()
	t.max_speed = config.run_speed if config != null else 7.0
	t.gravity = config.gravity if config != null else 20.0
	t.jump_height = config.jump_height if config != null else 1.25

	# [b]No bunny hopping, and the course is why.[/b] Every jump on a course is measured
	# against a running jump at the run speed (`tools/check_reach` in mg-wipeout-maps, and
	# the suite); a player who could chain hops would clear gaps a mapper meant to be the
	# hard part, and the course would be about a movement trick instead of the obstacles.
	t.auto_hop = false

	# Shift is the walk here, as in mg-smash-copter, and for a reason of this game's own:
	# the narrow beams and the balls are crossed slowly, and a walk on the key everybody
	# already reaches for is the control a beam asks for.
	t.walk_speed_scale = config.walk_speed_scale if config != null else 0.45
	t.can_walk = true
	t.can_sprint = false
	t.can_crouch = true
	t.crouch_speed_scale = 0.4

	t.accelerate = 10.0
	t.friction = 6.5
	t.stop_speed = 3.0

	# More air control than the round-based shooters give, less than a surf map. A course is
	# a series of jumps a player commits to, and enough air control to correct a jump that
	# was slightly off is what separates "I mistimed that" from "the game threw me".
	t.air_accelerate = 30.0
	t.max_air_wish_speed = 1.4

	t.coyote_time = 0.1
	t.jump_buffer_time = 0.12

	# The big balls are spheres, and a player stands on one only near its top. Thirty-five
	# degrees is about a third of the way down a ball, which is the target a jump onto one
	# has to hit.
	t.max_slope_angle = 35.0
	t.step_height = 0.4

	return t


## Registers the movement actions, and binds the slow walk to shift. See mg-smash-copter.
static func register_actions(p_sampler: DotFpsSampler = null) -> void:
	var _added := DotFpsSampler.register_default_actions(p_sampler)
	var walk := &"dot_fps_walk"

	if not InputMap.has_action(walk):
		return

	for event in InputMap.action_get_events(walk):
		var key := event as InputEventKey

		if key != null and key.physical_keycode == KEY_SHIFT:
			return

	var shift := InputEventKey.new()
	shift.physical_keycode = KEY_SHIFT
	InputMap.action_add_event(walk, shift)


## The clear air a running player crosses in one jump, landing [param rise] metres higher.
##
## dot-player-controller's own arithmetic over this game's tunables, so a cvar that shortens
## the jump shortens every check that reads this.
static func jump_reach(config: WoConfig, rise: float = 0.0) -> float:
	return tunables_for(config).jump_reach(rise)


## Called once per simulated tick by the world, on the server and offline.
func simulate(tick: int, delta: float) -> void:
	if sampler != null:
		controller.apply_command(sampler.sample(delta))

	controller.simulate_tick(tick, delta)


## Before the motor: the course where it is on this tick.
func _before_tick(tick: int) -> void:
	if stage != null and is_instance_valid(stage):
		stage.pose_at(tick)


## After the motor: what the course does to whoever is standing on it, or in its way.
##
## [b]In this order, and the order is the design.[/b] The carry first, because it is where the
## ground took them while they stood on it; the bounce, because a bouncer is ground; the
## knock last, because it is measured where they have ended up. Each writes the STATE and the
## node together: the controller starts its next tick from `state.position`, so a displacement
## applied only to the node is undone by the very next move — mg-smash-copter found that as a
## player riding a platform for one frame each tick.
func _after_tick(tick: int, state: DotFpsState) -> void:
	global_position = state.position

	if stage == null or not is_instance_valid(stage) or watching:
		return

	if state.mode == DotFpsState.Mode.GROUND and state.ground_id != 0:
		var moved := stage.carry(state.ground_id, state.position, tick)

		if moved != Vector3.ZERO:
			state.position += moved

		var up := stage.bounce(state.ground_id)

		if up > 0.0:
			state.velocity.y = up
			state.mode = DotFpsState.Mode.AIR

	# The wind, a push every tick it blows; half as hard on somebody standing, because the
	# ground holds them. In the state, so it is predicted like everything else here.
	var gust := stage.wind(tick)
	if gust != Vector3.ZERO:
		var hold := 0.5 if state.mode == DotFpsState.Mode.GROUND else 1.0
		state.velocity += gust * hold * delta_for_tick()

	var bolt := stage.strike(state.position, tick)
	if bolt != Vector3.ZERO:
		_knocked_tick = tick
		knocks += 1
		last_knock_speed = Vector2(bolt.x, bolt.z).length()
		last_knock_struck = true
		state.velocity = bolt
		state.mode = DotFpsState.Mode.AIR
		state.position.y += 0.05

	if tick - _knocked_tick > 6:
		var thrown := stage.knock(state.position, state.is_crouched(), tick, knock_limits)

		if thrown != Vector3.ZERO:
			_knocked_tick = tick
			knocks += 1
			last_knock_speed = Vector2(thrown.x, thrown.z).length()
			last_knock_struck = false
			state.velocity = thrown
			state.mode = DotFpsState.Mode.AIR
			# Lifted clear of the ground this tick, or the motor's ground snap takes the throw
			# straight back on the next one and the knock reads as a stumble.
			state.position.y += 0.05

	global_position = state.position


func delta_for_tick() -> float:
	return 1.0 / float(maxi(tick_rate, 1))


## Where this player's eyes are, from the simulated state rather than the drawn node.
func eye_position() -> Vector3:
	return controller.state.position + Vector3(0.0, EYE_HEIGHT, 0.0)


## The duck-typed lookup dot-weapon's player bridge asks a carrier for. Without it every shot
## leaves the player's feet pointing north; see mg-smash-copter.
func component(type_name: StringName) -> Object:
	match String(type_name):
		"DotPlayerController", "DotFpsController":
			return controller
		"DotHealth":
			return health
		"ZeeWeaponRig":
			return weapons
		_:
			return null


## Which way they are looking, as a unit vector. From yaw and pitch, never a camera.
func aim_direction() -> Vector3:
	var view := Basis.from_euler(Vector3(
		deg_to_rad(controller.state.pitch), deg_to_rad(controller.state.yaw), 0.0
	))
	return -view.z


## Puts a player somewhere, facing somewhere, with nothing carried over.
##
## [b]The state, the node and the pending command together[/b], and every one of the three
## was a separate bug in mg-smash-copter: the velocity (a player arriving still carrying a
## fall), `teleport` (the drawn view sweeping across the map for a frame) and the command
## (the motor taking the yaw back on the next tick from a command that still said north).
func place_at(at: Vector3, yaw_degrees: float) -> void:
	warps += 1
	global_position = at
	controller.teleport(at, yaw_degrees, 0.0)

	if sampler != null:
		sampler.look_at_angles(yaw_degrees, 0.0)

	var facing := DotFpsCommand.new()
	facing.yaw = yaw_degrees
	facing.pitch = 0.0
	controller.apply_command(facing)


## Back to the start of a round: nothing crossed, nothing finished, nothing held.
func reset_progress() -> void:
	checkpoint = -1
	finished = false
	place = 0
	finish_seconds = 0.0
	falls = 0
	knocks = 0
	watching = false
	_knocked_tick = -1000


func retune() -> void:
	if controller == null:
		return

	controller.tunables = tunables_for(config)

	if sampler != null:
		sampler.tunables = controller.tunables


func is_alive() -> bool:
	return health == null or health.alive


## Draws [member beacon] at [param at]. Client side; see mg-smash-copter's `present_beacon`.
func present_beacon(delta: float, at: Vector3, local_view: bool) -> bool:
	if not beacon or not is_alive():
		if beacon_marker != null:
			beacon_marker.queue_free()
			beacon_marker = null
		return false

	if beacon_marker == null:
		beacon_marker = WoBeacon.new()
		beacon_marker.name = "Beacon"
		add_child(beacon_marker)

	beacon_marker.local_view = local_view
	beacon_marker.global_position = at
	return beacon_marker.advance(delta)


## Draws this player's body for one frame at [param at]. Client side. Returns whether shown.
##
## Shown for everybody but the one the camera belongs to in first person, and anybody dead.
func present_body(own_view: bool, at: Vector3, team_colour: Color) -> bool:
	var shown := not own_view and is_alive()

	if figure == null:
		if not shown:
			return false

		figure = WoFigure.new()
		figure.name = "Figure"
		add_child(figure)

	var atlas := _atlas()

	if figure.atlas != atlas or not figure.team_colour.is_equal_approx(team_colour):
		var height := controller.tunables.stand_height \
			if controller != null and controller.tunables != null else 1.8
		figure.build(height, atlas, team_colour)

	figure.visible = shown

	if shown:
		_present_held()

	if shown and controller != null:
		var velocity := controller.state.velocity
		figure.pose(at, deg_to_rad(controller.state.yaw), Vector2(velocity.x, velocity.z).length())

	return shown


## Records a weapon the server dealt them. [param round_number] is the client's round.
func note_dealt(weapon_id: StringName, round_number: int) -> void:
	if round_number != dealt_round:
		dealt.clear()
		dealt_round = round_number

	if not dealt.has(weapon_id):
		dealt.append(weapon_id)


## Tells the figure what is in this player's hand this frame, and whether it went off.
func _present_held() -> void:
	var rig := _rig()
	var id := &""
	var switching := false
	var fired := 0
	var kind := 0

	if rig != null and rig.arsenal != null:
		var def := rig.arsenal.current_def()
		id = def.id if def != null else &""
		switching = rig.arsenal.is_switching()
		var seq := rig.fire_seq % ZeeWeaponNet.FIRE_SEQ_WRAP
		fired = ZeeWeaponNet.uses_between(_seen_fire_seq, seq) if _seen_fire_seq >= 0 else 0
		_seen_fire_seq = seq
		kind = rig.fire_kind
	elif mirrored:
		id = held_by_slot(dealt, mirror_slot)
		switching = mirror_switching
		fired = mirror_fired
		kind = mirror_fire_kind

	mirror_fired = 0
	figure.hold(id, switching)
	figure.fired(fired, kind)


## Which of [param ids] is in [param slot], or nothing. The first dealt wins a shared slot,
## which is the one the server selects at the handover.
static func held_by_slot(ids: Array[StringName], slot: int) -> StringName:
	if slot <= 0 or ids.is_empty():
		return &""

	if _slots.is_empty():
		for def in ZeeWeaponPack.weapons():
			_slots[def.id] = def.slot

	for id in ids:
		if int(_slots.get(id, -1)) == slot:
			return id

	return &""


## The rig this process simulates them with: the server's, an offline stand-in's, or the
## one a networked client builds for its own player's hands (`WoClient._arm_locally`, which
## hangs it on the player without setting [member weapons], because a client must not hand
## its rig to the simulation's lookups).
func _rig() -> ZeeWeaponRig:
	if weapons != null:
		return weapons

	return get_node_or_null(^"Weapons") as ZeeWeaponRig


func _atlas() -> String:
	var index := WoAvatars.skin_index(avatar)

	if index < 0 or index >= WoFigure.ATLASES.size():
		index = WoAvatars.stock_index(player_id)

	return str(WoFigure.ATLASES[index])


func describe() -> Dictionary:
	return {
		"id": String(player_id),
		"side": team,
		"alive": is_alive(),
		"health": health.health if health != null else 0.0,
		"checkpoint": checkpoint,
		"finished": "#%d in %.1f s" % [place, finish_seconds] if finished else "no",
		"falls": falls,
		"knocks": knocks,
		"watching": watching,
		"armed": weapons != null,
		"carrying": grab != null and grab.is_carrying(),
		"blinded": blinded,
		"beacon": beacon,
		"avatar": avatar.digest() if avatar != null else "stock",
	}
