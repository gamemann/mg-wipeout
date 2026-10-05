extends DotNetBehaviour

## What a prop replicates: where it is and how it is turned.
##
## [b]Server-authoritative and never predicted, and that is a decision rather than an
## omission.[/b] Godot's rigid-body solver is not reproducible across machines — island
## ordering, sleep thresholds and contact caching all differ — so a client predicting a
## sky full of falling crates would disagree with the server within a second and be
## corrected continuously. In this game it matters more than in most: a prop is a thing
## that is about to land on a platform, and a prop a few centimetres out on a client is a
## player who dodged the wrong way.
##
## The consequence a player feels is that a crate they watched leave the tube is drawn
## about a snapshot behind where the server has it, and that is the correct trade: a
## wrong-but-immediate crate that snaps back is worse than a right one that arrives a
## moment late.

var prop: Node3D = null

var net_position: Vector3 = Vector3.ZERO
var net_rotation: Quaternion = Quaternion.IDENTITY


func _register_net_vars() -> void:
	replicate(&"net_position", DotNetVar.Type.VECTOR3_POSITION).interpolated()
	# Smallest-three, nine bits an element. A tumbling crate's orientation does not need
	# more: the error is under a degree, and nobody aligns a falling crate to a degree.
	replicate(&"net_rotation", DotNetVar.Type.QUATERNION).bits(9).interpolated()


## Authority only. The body is moved by the physics server; this copies where it ended up
## into the replicated properties.
func pull() -> void:
	if not _drawable():
		return

	net_position = prop.global_position
	net_rotation = prop.global_basis.get_rotation_quaternion()


## Whether this behaviour's body can still be asked where it is.
##
## [b]`is_inside_tree` as well as `is_instance_valid`, and the second is not enough.[/b] A
## round re-lays the field from inside the netcode's own loop over replicated entities, so
## a body taken out of the tree and queued for freeing is an entirely expected state for
## the rest of that frame — and `global_position` on one is
## `Condition "!is_inside_tree()" is true`, with a full backtrace, once per body per tick.
## To an operator reading a log that is indistinguishable from a crash. dot-entity guards
## its own `position()` for exactly this reason and writes down why.
func _drawable() -> bool:
	return prop != null and is_instance_valid(prop) and prop.is_inside_tree()


## Where this body is, for anything that does not care what kind of body it is.
##
## [b]A method and not a property read, because a chopper does not use [member
## net_position].[/b] [WoCopterNet] replicates through [DotVehicleNetSync], whose layout is
## three separate floats — so code that read `net_position` off a mirrored chopper got the
## zero it was constructed with, and a joining player was told every machine in the map was
## at the origin. It was the announcement to a late joiner that had it in
## game-buses-from-hell, which is the one path a suite that joins first never takes.
func replicated_position() -> Vector3:
	return net_position


func _net_simulate(_tick: int, _delta: float) -> void:
	if identity != null and identity.is_authoritative:
		pull()


## A mirrored prop, on a snapshot. Written straight to the node: nothing here is predicted,
## so there is no reconciliation to spoil by moving it.
func _net_state_applied(_tick: int) -> void:
	_draw()


## Every frame between snapshots. Without this a crate steps at the snapshot rate however
## smoothly the interpolator did its work — the family's own "produced correctly and
## consumed by nothing", which has cost dot-net two bugs.
func _net_interpolated(_tick: int) -> void:
	_draw()


func _draw() -> void:
	if not _drawable():
		return

	if identity != null and identity.is_authoritative:
		return

	prop.global_position = net_position
	prop.global_basis = Basis(net_rotation)

	# A mirrored body must not be simulated locally as well. Freezing it is not cosmetic:
	# an unfrozen [RigidBody3D] fights every position written into it, and what that looks
	# like is a crate juddering against gravity while the packets say it is falling
	# smoothly.
	var body := prop as RigidBody3D

	if body != null and not body.freeze:
		body.freeze = true
