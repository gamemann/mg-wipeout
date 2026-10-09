extends DotNetBehaviour

const WoNetCommand := preload("wo_net_command.gd")
const WoPlayer := preload("../wo_player.gd")

## What a networked player replicates: the movement state, their health, and where they are
## on the course.
##
## [b]The movement half is dot-player-controller's own table and is not written here.[/b]
## [DotFpsNetSync.state_specs] is what the controller says its state is, in the
## quantisation it says it wants; a game that listed the fields itself would be a second
## copy to drift — and the type names in that table are STRINGS precisely so the addon can
## describe a dot-net layout without naming dot-net.
##
## [b]The game fields are not derivable from the movement.[/b] Health decides whether a body
## is drawn at all; the checkpoint, the finish and the gallery are the server's decisions
## about a runner, and a client that worked them out for itself would be running a second
## copy of the rules.
##
## [b]Which side somebody is on is deliberately NOT here.[/b] It changes once a round at
## most, and a per-tick field for it would send the same three bits sixty-four times a
## second for ever to carry a fact that arrives reliably in a JOIN and a TEAM. The rule this
## game follows: a per-tick property for what changes per tick, an event for what changes on
## a decision.

## Somebody this client is watching used their weapon, [param times] times since the last
## snapshot. What a game draws a muzzle flash from.
signal weapon_used(times: int, kind: int)

var player: WoPlayer = null
var bridge: Node = null

var net_position: Vector3 = Vector3.ZERO
var net_velocity: Vector3 = Vector3.ZERO
var net_yaw: float = 0.0
var net_pitch: float = 0.0
var net_crouch: float = 0.0
var net_flags: int = 0
var net_modifiers: int = 0

## Hit points, and the one field with a hard cap on the wire.
##
## [b]Sent against 0..1000 rather than against the player's own maximum.[/b] A server that
## raised `player_health` mid-round would otherwise change what every previously sent number
## MEANT, which is the quantisation version of the map-size bug: the value does not get less
## precise, it becomes a different value.
var net_health: float = 100.0

## Where they are on the course, which the HUD of everybody watching reads: the checkpoint
## (offset by one, so "none" is zero on the wire) and whether they are across.
var net_checkpoint: int = 0
var net_finished: bool = false

## Points this match and the server's last ping for the player, for everybody's Tab board.
var net_points: int = 0
var net_ping: int = 0

## In the gallery, watching a final death they did not reach.
var net_watching: bool = false

## Carrying a prop on the gravity gun, which only the server runs. One bit, so a watcher
## draws both arms out under the prop instead of a crate following somebody about.
var net_carrying: bool = false

# --- The weapons, which only exist in the second half of a round ------------
#
# [b]Seven fields, and the pack's own `all_specs()` names all of them.[/b] GDScript has no
# dynamic properties, so a spec table that says what to send needs a variable per entry
# declared by hand — and the one call a game should make is `ZeeWeaponNet.all_specs()`,
# because concatenating dot-weapon's three with the pack's four by hand is the same work
# and one more place to forget the second half. Forgetting it presents as weapons that are
# silent for everybody except the person holding them, which is what game-playground
# shipped.
#
# The magazine and the reserve are `owner_only`: exact ammunition is information an opponent
# should not have, and dot-combat makes the same decision about the same two numbers.

var net_slot: int = 0
var net_magazine: int = 0
var net_reserve: int = 0
var net_fire_seq: int = 0
var net_fire_kind: int = 0
var net_reloading: bool = false
var net_switching: bool = false

# --- An administrator's marks, from the live tools ---------------------------

## `WoPlayer.blinded`. Owner only: see [method _register_net_vars].
var net_blind: bool = false

## `WoPlayer.beacon`. Everybody's.
var net_beacon: bool = false

## `WoPlayer.warps`, four bits of it: how many times the server has put this player
## somewhere rather than moved them there. See [method _forget_the_path].
var net_warp: int = 0

## The last [member net_warp] this mirror acted on.
var _seen_warp: int = -1

## What this watcher last saw of that counter, so a wrap is read as uses rather than as a
## negative. One integer per watched player, which is what lets `ZeeWeaponNet` keep none.
var _seen_fire_seq: int = 0

## Retained, not cleared: a player whose packet was lost keeps moving in a straight line
## rather than stopping dead. The controller says the same of its own command.
var last_move: DotFpsCommand = DotFpsCommand.new()

## And the slot they last asked for, which is simulation state on the showdown's side of
## the round: the arsenal is edge-triggered against it.
var last_slot: int = 0

var last_grab: bool = false

var last_state_tick: int = -1


func _register_net_vars() -> void:
	for spec in DotFpsNetSync.state_specs():
		var declaration := replicate(spec["property"], DotNetVar.Type[spec["type"]])

		if int(spec["bits"]) > 0:
			declaration.bits(int(spec["bits"]))

		if bool(spec["interpolated"]):
			declaration.interpolated()

		if spec["property"] == &"net_crouch":
			declaration.range_of(0.0, 1.0)

	replicate(&"net_health", DotNetVar.Type.FLOAT_RANGE).range_of(0.0, 1000.0).bits(12)
	replicate(&"net_checkpoint", DotNetVar.Type.UINT).bits(6)
	replicate(&"net_finished", DotNetVar.Type.BOOL)
	replicate(&"net_points", DotNetVar.Type.UINT).bits(16)
	replicate(&"net_ping", DotNetVar.Type.UINT).bits(10)
	replicate(&"net_watching", DotNetVar.Type.BOOL)
	replicate(&"net_carrying", DotNetVar.Type.BOOL)

	for spec in ZeeWeaponNet.all_specs():
		var declaration := replicate(spec["property"], DotNetVar.Type[spec["type"]])

		if int(spec["bits"]) > 0:
			declaration.bits(int(spec["bits"]))

		if bool(spec["interpolated"]):
			declaration.interpolated()

		if bool(spec["owner_only"]):
			var _owner := declaration.to_owner_only()

	# [b]Per-player state rather than an event, and that is what makes both of these survive
	# what an event does not.[/b] A client that joins after the admin typed `beacon`, a
	# snapshot lost on the way, a field re-laid at the top of a round: each is a baseline the
	# next snapshot corrects, where an event sent once is simply missed. Two bits, and nothing
	# at all on a tick where neither changed.
	#
	# The blind goes to its owner alone. Nobody else's screen changes, and an opponent who
	# received it would know the moment somebody could not see — the same reason the magazine
	# and the reserve above are the owner's.
	#
	# [b]No relevance change for a beacon, where game-arena makes one.[/b] Every player here
	# is already always relevant (`WoNetBridge`: the map is open air), so a beacon reaches
	# every client however far away they are without asking — and a beacon turned OFF that
	# set `always_relevant` back to false would take the player out of everybody's snapshot.
	var _blind := replicate(&"net_blind", DotNetVar.Type.BOOL).to_owner_only()
	replicate(&"net_beacon", DotNetVar.Type.BOOL)
	replicate(&"net_warp", DotNetVar.Type.UINT).bits(4)


func _net_apply_input(input: DotNetInput, _tick: int) -> void:
	var command := input as WoNetCommand

	if command != null:
		last_move = command.move
		last_slot = command.slot
		last_grab = command.grab

		if player != null:
			player.wanted_slot = command.slot
			player.wants_grab = command.grab


## On the authority the whole game ticks as one — every player moves, then the platforms
## are loaded and stepped, then what landed on what is decided — so the first behaviour
## through drives the whole world and the rest find it done. On a predicting client there
## is one predicted player, and simulating it is the whole of what a client may compute: the
## props, the platforms and the choppers are all somebody else's answer.
func _net_simulate(tick: int, delta: float) -> void:
	if player == null:
		return

	if identity != null and identity.is_authoritative:
		if bridge != null:
			bridge.ensure_game_ticked(tick)
	else:
		# The prediction: the controller's own tick, which poses the course at this tick
		# first and lets it act on the player after (see [WoController]) — the same three
		# steps the server takes, so a knock predicted here is the knock the server decides.
		player.controller.apply_command(last_move.duplicate_command())
		player.controller.simulate_tick(tick, delta)

	pull()


## Authority only: what the simulation left this player as.
func pull() -> void:
	if player == null:
		return

	DotFpsNetSync.pull(player.controller.state, self)

	if player.health != null:
		net_health = player.health.health

	net_checkpoint = clampi(player.checkpoint + 1, 0, 63)
	net_finished = player.finished
	net_points = clampi(player.points, 0, 65535)
	net_ping = clampi(player.ping_ms, 0, 1023)
	net_watching = player.watching
	net_carrying = player.grab != null and player.grab.is_carrying()
	net_blind = player.blinded
	net_beacon = player.beacon
	net_warp = player.warps & 0xF

	# [b]After the arsenal has simulated, which on this end it has: the whole world ticks
	# before anything is pulled.[/b] A rig that does not exist yet — which is every player
	# for the first two thirds of a round — leaves these at zero, and zero is a carrier
	# holding nothing, which is true.
	if player.weapons != null:
		ZeeWeaponNet.pull(player.weapons, self)


## The server's answer, adopted wholesale. On the owner it is the rewind half of
## reconciliation and the predictor replays every unacknowledged command on top.
func _net_state_applied(tick: int) -> void:
	if player == null:
		return

	last_state_tick = tick
	_forget_the_path()
	DotFpsNetSync.push(self, player.controller.state)
	_adopt()

	# NOT the node, on a predicted entity: `receive_snapshot` calls this BEFORE the
	# predictor reconciles, and reconcile's first act is to read the node as "what the
	# client is showing". Moving it here makes the measured error the whole replay distance,
	# and the correction rate then reads as if every snapshot snapped. Two games in this
	# family shipped that line.
	#
	if identity == null or not identity.is_predicted():
		player.global_position = player.controller.state.position


## A teleport is not a movement, so the interpolator must not draw one.
##
## [b]The showdown moves every survivor sixty metres in one tick, and a watcher saw them fly
## there.[/b] The interpolator blends between the two snapshots either side of the render
## time, and when those are "on a platform" and "in a corner of the sky" the blend is a body
## sweeping across the map for a snapshot interval — seven frames of it at four frames a
## tick, measured by `headless_net`. Every round start is the same, since laying the field
## out again puts everybody back on a deck with the same call.
##
## So the server counts the times it PUT this player somewhere (`WoPlayer.place_at`), the
## count replicates, and a mirror that sees it change drops the interpolator's track for this
## entity before the new snapshot is added to it. A track with one sample answers with that
## sample, so the body appears in its corner, one render delay early, rather than crossing
## the sky to get there. Here, before the push, because this hook runs inside the snapshot
## read and the manager adds the snapshot's values to the track just after it.
##
## Not on the predicted entity: nothing interpolates that, and its own camera is moved by
## the prediction's rewind.
func _forget_the_path() -> void:
	if identity == null or identity.is_authoritative or identity.is_predicted():
		_seen_warp = net_warp
		return

	if _seen_warp >= 0 and net_warp != _seen_warp and bridge != null:
		var manager: Variant = bridge.get(&"net")
		if manager is DotNetManager and (manager as DotNetManager).interpolator != null:
			(manager as DotNetManager).interpolator.forget(identity.net_id)

	_seen_warp = net_warp


## Every frame on a remote player. Without this the interpolator's work sits in a property
## nothing reads and a remote player moves in snapshot-sized steps.
func _net_interpolated(_tick: int) -> void:
	if player == null:
		return

	DotFpsNetSync.push(self, player.controller.state)
	player.global_position = player.controller.state.position


## The game half of a snapshot, on a mirror: what the server decided about this runner.
func _adopt() -> void:
	if player == null or identity == null or identity.is_authoritative:
		return

	if player.health != null:
		player.health.health = net_health
		player.health.alive = net_health > 0.0

	player.checkpoint = net_checkpoint - 1
	player.finished = net_finished
	player.points = net_points
	player.ping_ms = net_ping
	player.watching = net_watching
	player.carrying = net_carrying

	player.blinded = net_blind
	player.beacon = net_beacon

	_apply_weapons()


## What a watcher does with somebody else's weapon state.
##
## [b]A counter, never an event per shot.[/b] An RPC per shot needs a reliable channel for
## something worthless if it arrives late, costs a packet per shot per watcher, and
## desynchronises from the state it belongs with — so a watcher can see the muzzle flash of
## a weapon the same snapshot says has been holstered. A four-bit counter inside the
## snapshot cannot do any of those: a watcher who missed a snapshot sees it jump by two and
## plays one flash instead of two, which is the correct amount of wrong.
##
## [b]No world model is handed to `ZeeWeaponNet.apply`[/b], because the hand it would hang
## from belongs to the figure, which is built lazily, rebuilt on a side change and absent on
## a server. The answer is written onto the player instead — the slot, the switch and the
## uses since the figure last looked — and `WoPlayer.present_body` hands it to the figure on
## the frame it is drawn. The same counter also says `weapon_used`, which is the report.
func _apply_weapons() -> void:
	var answer := ZeeWeaponNet.apply(self, null, _seen_fire_seq)
	_seen_fire_seq = int(answer["seq"])

	player.mirrored = true
	player.mirror_slot = net_slot
	player.mirror_switching = net_switching
	player.mirror_fired += int(answer["fired"])
	if int(answer["fired"]) > 0:
		player.mirror_fire_kind = int(answer["kind"])

	if int(answer["fired"]) > 0:
		weapon_used.emit(int(answer["fired"]), int(answer["kind"]))
