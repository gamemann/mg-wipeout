extends Node3D

const WoCourseDoc := preload("wo_course_doc.gd")
const WoTextures := preload("wo_textures.gd")

## A course, or an arena, built from its document: the pieces, where each one is at a given
## tick, and the four questions a player's movement asks of them.
##
## [b]An obstacle is a pure function of the tick, and that is the decision this file
## exists for.[/b] mg-smash-copter's platforms are a spring the server integrates and tells
## every client about, because what they do depends on who is standing on them. Nothing here
## does: an arm turns at a speed, a mover slides with a period, a tile drops on a schedule —
## so where any of it is on tick N is a formula both ends evaluate and nobody has to send.
## No obstacle is a replicated entity, no snapshot carries one, and a client predicting its
## own player on tick N poses every obstacle at tick N first, so a jump over a sweeping arm
## lands or fails identically on the client and the server.
##
## [b]Three kinds of piece, by what they do to a player:[/b]
##
## - [b]still[/b] (box, ramp, ball, cylinder): a static collider and nothing else;
## - [b]carriers[/b] (mover, turntable, roller, seesaw, conveyor) and the two specials (tiles,
##   bouncer): solid, and whoever stands on one is moved with it by [method carry] — after
##   the motor has run, because the motor writes an absolute position and anything applied
##   before it is overwritten. That ordering is mg-smash-copter's platform carry, unchanged;
## - [b]hazards[/b] (spinner, pendulum, pusher): NOT solid to a player. They are measured
##   instead ([method knock]), against the player's capsule, every tick. A swept capsule
##   meeting a body that moved into it between two ticks is resolved by depenetration, which
##   is order-dependent and different on two machines; an analytic overlap of two shapes is
##   the same arithmetic everywhere, and it is what lets the knock be predicted.
##
## [b]Built the same on a server and a client.[/b] The meshes cost a server nothing it
## renders; [member draw_world] adds the sky, the sun and the water, which only a client sees.

const CHANNEL := "wo.course"

## The capsule a player is measured as, in metres. Matches [WoPlayer]'s tunables.
const PLAYER_RADIUS := 0.35
const PLAYER_HEIGHT := 1.8
const PLAYER_CROUCHED := 0.9

## How far a dropped tile goes, in metres. Out of the way, and back on the same schedule.
const TILE_DROP := 60.0

## Seconds before a tile drops that it shakes and changes colour. See [method tile_warning].
const TILE_WARN_SECONDS := 0.6

## How far below a start gate goes when it opens.
const GATE_DROP := 80.0

## Emitted when the course has been built and posed once.
signal built()

## Whether to draw the sky, the sun and the water. A client sets this; a server need not.
@export var draw_world: bool = false

## The collision layout everything is put on. Set by [WoGame] before [method build].
var physics: DotPhysicsLayout = null

## The normalised document this was built from. See [WoCourseDoc].
var doc: Dictionary = {}

## Ticks a second, for turning a tick into the time every formula is written in.
var tick_rate: int = 64

## Whether the start gate stands. [WoGame] closes it for the countdown.
var gate_closed: bool = false:
	set(value):
		gate_closed = value
		_place_gate()

## One per piece, in document order. See [method _make_piece].
var pieces: Array[Dictionary] = []

## Collider instance id -> [code][piece index, sub-index][/code], for the carry and the bounce.
var _by_collider: Dictionary = {}

## The tick the moving pieces were last posed at, so a second call for the same tick is free.
var _posed_tick: int = -2147483648
var _posed_time: float = -1.0

var _gate: StaticBody3D = null
var _gate_rest: Transform3D = Transform3D.IDENTITY


# --- Building ---------------------------------------------------------------

## Builds everything [param p_doc] describes, replacing whatever was here.
##
## [b]The old pieces are taken out of the tree now and freed at the end of the frame.[/b]
## A round can change course inside the netcode's own tick, and freeing a body there frees
## something [DotNetManager.server_tick] may still be walking — mg-smash-copter's
## `ScPlatforms.clear` is the same two lines for the same reason.
func build(p_doc: Dictionary) -> DotResult:
	clear()

	var checked := WoCourseDoc.validate(p_doc)

	if not checked.ok:
		return checked

	doc = checked.value

	for index in range((doc["pieces"] as Array).size()):
		_make_piece(index, doc["pieces"][index])

	if is_course():
		_build_start()
		_build_markers()

	if is_arena():
		_build_gallery()

	if draw_world:
		_build_world()

	pose_at_time(0.0)
	built.emit()

	DotLog.debug(CHANNEL, "built", {
		"id": id(), "kind": str(doc.get("kind", "")), "pieces": pieces.size(),
		"digest": WoCourseDoc.digest(doc),
	})
	return DotResult.success(self)


func clear() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()

	pieces.clear()
	_by_collider.clear()
	doc = {}
	_gate = null
	_posed_tick = -2147483648
	_posed_time = -1.0


func id() -> StringName:
	return StringName(str(doc.get("id", "")))


func is_course() -> bool:
	return str(doc.get("kind", "")) == WoCourseDoc.KIND_COURSE


func is_arena() -> bool:
	return str(doc.get("kind", "")) == WoCourseDoc.KIND_ARENA


func _make_piece(index: int, spec: Dictionary) -> void:
	var kind := str(spec["kind"])
	var role := _role(str(spec.get("role", "deck")))
	var piece := {
		"index": index,
		"kind": kind,
		"spec": spec,
		"node": null,
		"moving": false,
		"carrier": false,
		"hazard": false,
		"bodies": [],
	}

	match kind:
		"box":
			piece["node"] = _static_box(spec["at"], spec["size"], spec["yaw"], 0.0, role)
		"ramp":
			piece["node"] = _static_box(spec["at"], spec["size"], spec["yaw"], float(spec["pitch"]), role)
		"ball":
			piece["node"] = _static_round(spec, role, true)
		"cylinder":
			piece["node"] = _static_round(spec, role, false)
		"mover":
			piece["node"] = _moving_box(spec["size"], role)
			piece["moving"] = true
			piece["carrier"] = true
		"turntable":
			piece["node"] = _moving_disc(float(spec["radius"]), float(spec.get("thickness", 0.6)), role)
			piece["moving"] = true
			piece["carrier"] = true
		"roller":
			piece["node"] = _moving_log(float(spec["length"]), float(spec["radius"]), role)
			piece["moving"] = true
			piece["carrier"] = true
		"seesaw":
			piece["node"] = _moving_box(spec["size"], role)
			piece["moving"] = true
			piece["carrier"] = true
		"conveyor":
			piece["node"] = _conveyor(spec, role)
			piece["moving"] = true
			piece["carrier"] = true
		"bouncer":
			piece["node"] = _static_box(spec["at"], spec["size"], spec["yaw"], 0.0, role)
		"tiles":
			piece["node"] = _tiles(spec, role)
			piece["moving"] = true
		"spinner":
			piece["node"] = _spinner(spec, role)
			piece["moving"] = true
			piece["hazard"] = true
		"pendulum":
			piece["node"] = _pendulum(spec, role)
			piece["moving"] = true
			piece["hazard"] = true
		"pusher":
			piece["node"] = _pusher(spec, role)
			piece["moving"] = true
			piece["hazard"] = true

	var node: Node3D = piece["node"]

	if node == null:
		return

	node.name = "%s_%d" % [kind, index]
	add_child(node)

	# Every collider in the piece, so a ground id finds its piece in one lookup.
	var bodies: Array = []
	_collect_bodies(node, bodies)

	for sub in range(bodies.size()):
		var body: CollisionObject3D = bodies[sub]
		_by_collider[body.get_instance_id()] = [index, sub]
		_put_on_world_layer(body)

	piece["bodies"] = bodies
	pieces.append(piece)


func _collect_bodies(node: Node, into: Array) -> void:
	if node is CollisionObject3D:
		into.append(node)

	for child in node.get_children():
		_collect_bodies(child, into)


func _put_on_world_layer(body: CollisionObject3D) -> void:
	if physics == null:
		return

	var applied := physics.apply_to(body, &"world")

	if not applied.ok:
		DotLog.warn(CHANNEL, "a piece could not be put on its collision layer", {
			"why": applied.error.message,
		})


static func _role(name: String) -> WoTextures.Role:
	match name:
		"pillar":
			return WoTextures.Role.PILLAR
		"cannon":
			return WoTextures.Role.CANNON
		"arena":
			return WoTextures.Role.ARENA
		"hazard":
			return WoTextures.Role.HAZARD
		"safe":
			return WoTextures.Role.SAFE
		_:
			return WoTextures.Role.DECK


static func _yaw_basis(yaw_degrees: float) -> Basis:
	return Basis(Vector3.UP, deg_to_rad(yaw_degrees))


func _static_box(at: Vector3, size: Vector3, yaw: float, pitch: float, role: WoTextures.Role) -> StaticBody3D:
	var body := StaticBody3D.new()
	# Pitch about the piece's own X axis, positive raising its far (-Z) end: a ramp a mapper
	# writes as "pitch 15" climbs away from the start the way the course runs.
	body.transform = Transform3D(_yaw_basis(yaw) * Basis(Vector3.RIGHT, deg_to_rad(pitch)), at)
	_add_box(body, size, role, false, true)
	return body


func _static_round(spec: Dictionary, role: WoTextures.Role, sphere: bool) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.transform = Transform3D(_yaw_basis(float(spec["yaw"])), spec["at"])

	var mesh := MeshInstance3D.new()
	var shape := CollisionShape3D.new()

	if sphere:
		var sphere_mesh := SphereMesh.new()
		sphere_mesh.radius = float(spec["radius"])
		sphere_mesh.height = float(spec["radius"]) * 2.0
		mesh.mesh = sphere_mesh

		var sphere_shape := SphereShape3D.new()
		sphere_shape.radius = float(spec["radius"])
		shape.shape = sphere_shape
	else:
		var cylinder := CylinderMesh.new()
		cylinder.top_radius = float(spec["radius"])
		cylinder.bottom_radius = float(spec["radius"])
		cylinder.height = float(spec["height"])
		mesh.mesh = cylinder

		var cylinder_shape := CylinderShape3D.new()
		cylinder_shape.radius = float(spec["radius"])
		cylinder_shape.height = float(spec["height"])
		shape.shape = cylinder_shape

	mesh.material_override = WoTextures.surface(role)
	body.add_child(mesh)
	body.add_child(shape)
	return body


func _add_box(parent: Node3D, size: Vector3, role: WoTextures.Role, moving: bool, solid: bool,
		offset: Vector3 = Vector3.ZERO) -> MeshInstance3D:
	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	mesh.mesh = box
	mesh.position = offset
	mesh.material_override = WoTextures.surface(role, moving)
	parent.add_child(mesh)

	if solid:
		var shape := CollisionShape3D.new()
		var box_shape := BoxShape3D.new()
		box_shape.size = size
		shape.shape = box_shape
		shape.position = offset
		parent.add_child(shape)

	return mesh


## A body the course moves by setting its transform each tick.
##
## [b]A STATIC body, teleported, and a kinematic one is wrong here in a way only a test with
## no physics frames between ticks shows.[/b] Godot's physics server applies a new transform
## to a KINEMATIC body (which is what an `AnimatableBody3D` is) only at its next step — the
## first one lands at once, every later one waits. So a client replaying six predicted ticks
## inside one frame swept all six against the obstacle where it was a frame ago, and the
## course suite, which drives ticks without frames, found the turntables and the rollers
## still standing at the origin where they were built, eighty metres from where their
## documents put them. A static body's transform is applied the moment it is set. Nothing is
## lost: nothing here is pushed by the solver (props excepted, and a prop knocked by a moving
## floor is cosmetic), and riding is [method carry]'s arithmetic, not a body velocity.
static func _animatable() -> StaticBody3D:
	return StaticBody3D.new()


## Puts [param body] at [param at] in the node AND in the physics server, now.
##
## [b]Both, and the node alone is a tick late.[/b] A node's new transform reaches the physics
## server through the scene tree's transform notifications, which are flushed at the next
## frame boundary — so a client replaying past ticks would sweep every one of them against
## obstacles where they were a frame ago. With [method _animatable]'s static bodies the
## server applies it at once.
static func _place(body: Node3D, at: Transform3D) -> void:
	body.transform = at

	if body is CollisionObject3D and body.is_inside_tree():
		PhysicsServer3D.body_set_state(
			(body as CollisionObject3D).get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM,
			body.global_transform
		)


func _moving_box(size: Vector3, role: WoTextures.Role) -> StaticBody3D:
	var body := _animatable()
	_add_box(body, size, role, true, true)
	return body


func _moving_disc(radius: float, thickness: float, role: WoTextures.Role) -> StaticBody3D:
	var body := _animatable()

	var mesh := MeshInstance3D.new()
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = radius
	cylinder.bottom_radius = radius
	cylinder.height = thickness
	cylinder.radial_segments = 48
	mesh.mesh = cylinder
	mesh.material_override = WoTextures.surface(role, true)
	body.add_child(mesh)

	# Two stripes across the top, because a disc of one colour turning under a grid that is
	# stuck to it still reads as still from most angles; a bar across it does not.
	for turn in range(2):
		var bar := MeshInstance3D.new()
		var bar_box := BoxMesh.new()
		bar_box.size = Vector3(radius * 1.9, 0.04, 0.5)
		bar.mesh = bar_box
		bar.position = Vector3(0.0, thickness * 0.5 + 0.02, 0.0)
		bar.rotation = Vector3(0.0, PI * 0.5 * turn, 0.0)
		bar.material_override = WoTextures.surface(WoTextures.Role.PILLAR, true)
		body.add_child(bar)

	var shape := CollisionShape3D.new()
	var cylinder_shape := CylinderShape3D.new()
	cylinder_shape.radius = radius
	cylinder_shape.height = thickness
	shape.shape = cylinder_shape
	body.add_child(shape)
	return body


func _moving_log(length: float, radius: float, role: WoTextures.Role) -> StaticBody3D:
	var body := _animatable()

	# Along the body's X axis: a cylinder is built along Y and turned onto X here, inside the
	# body, so the body's own rotation about X is the log rolling.
	var mesh := MeshInstance3D.new()
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = radius
	cylinder.bottom_radius = radius
	cylinder.height = length
	cylinder.radial_segments = 32
	mesh.mesh = cylinder
	mesh.rotation = Vector3(0.0, 0.0, PI * 0.5)
	mesh.material_override = WoTextures.surface(role, true)
	body.add_child(mesh)

	# Bands, for the same reason as the turntable's bars: a smooth log rolling is a log that
	# looks still.
	for band in range(4):
		var ring := MeshInstance3D.new()
		var ring_box := BoxMesh.new()
		ring_box.size = Vector3(length * 0.98, 0.12, radius * 2.04)
		ring.mesh = ring_box
		ring.rotation = Vector3(PI * 0.25 * band, 0.0, 0.0)
		ring.material_override = WoTextures.surface(WoTextures.Role.PILLAR, true)
		ring.scale = Vector3(1.0, 1.0, 0.98)
		body.add_child(ring)

	var shape := CollisionShape3D.new()
	var cylinder_shape := CylinderShape3D.new()
	cylinder_shape.radius = radius
	cylinder_shape.height = length
	shape.shape = cylinder_shape
	shape.rotation = Vector3(0.0, 0.0, PI * 0.5)
	body.add_child(shape)
	return body


## A belt: `speed` metres a second along its own -Z (negative runs it back toward the
## start), pitched like a ramp when `pitch` is given, so a belt can lie on a slope.
func _conveyor(spec: Dictionary, role: WoTextures.Role) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.transform = Transform3D(_conveyor_basis(spec), spec["at"])
	var size: Vector3 = spec["size"]
	_add_box(body, size, role, false, true)

	# Slats that run, client side, so the direction of the belt can be read off it. They are
	# moved by [method _pose_piece] and are nothing but meshes.
	var slats := Node3D.new()
	slats.name = "Slats"
	body.add_child(slats)

	var count := maxi(int(size.z / 1.5), 2)

	for i in range(count):
		var slat := MeshInstance3D.new()
		var slat_box := BoxMesh.new()
		slat_box.size = Vector3(size.x * 0.96, 0.05, 0.3)
		slat.mesh = slat_box
		slat.material_override = WoTextures.surface(WoTextures.Role.PILLAR, true)
		slats.add_child(slat)

	return body


static func _conveyor_basis(spec: Dictionary) -> Basis:
	return _yaw_basis(float(spec.get("yaw", 0.0))) * Basis(Vector3.RIGHT, deg_to_rad(float(spec.get("pitch", 0.0))))


func _tiles(spec: Dictionary, role: WoTextures.Role) -> Node3D:
	var root := Node3D.new()
	root.transform = Transform3D(_yaw_basis(float(spec["yaw"])), spec["at"])

	var cols := int(spec["cols"])
	var rows := int(spec["rows"])
	var tile := float(spec["tile"])
	var gap := float(spec.get("gap", 0.25))
	var thickness := float(spec.get("thickness", 0.5))
	var pitch := tile + gap

	for row in range(rows):
		for col in range(cols):
			var body := _animatable()
			body.name = "Tile_%d_%d" % [col, row]
			body.position = Vector3(
				(float(col) - float(cols - 1) * 0.5) * pitch,
				0.0,
				(float(row) - float(rows - 1) * 0.5) * pitch
			)
			body.set_meta(&"rest", body.position)
			_add_box(body, Vector3(tile, thickness, tile), role, true, true)
			root.add_child(body)

	return root


func _spinner(spec: Dictionary, role: WoTextures.Role) -> Node3D:
	var root := StaticBody3D.new()
	root.transform = Transform3D(_yaw_basis(float(spec["yaw"])), spec["at"])

	var arm_height := float(spec.get("arm_height", 1.0))
	var hub_radius := float(spec.get("hub_radius", 0.6))
	var hub_height := float(spec.get("hub_height", arm_height + 0.6))

	# The hub is solid: it is a post a player has to go round.
	var mesh := MeshInstance3D.new()
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = hub_radius
	cylinder.bottom_radius = hub_radius
	cylinder.height = hub_height
	mesh.mesh = cylinder
	mesh.position = Vector3(0.0, hub_height * 0.5, 0.0)
	mesh.material_override = WoTextures.surface(WoTextures.Role.PILLAR)
	root.add_child(mesh)

	var shape := CollisionShape3D.new()
	var cylinder_shape := CylinderShape3D.new()
	cylinder_shape.radius = hub_radius
	cylinder_shape.height = hub_height
	shape.shape = cylinder_shape
	shape.position = mesh.position
	root.add_child(shape)

	var arms := Node3D.new()
	arms.name = "Arms"
	arms.position = Vector3(0.0, arm_height, 0.0)
	root.add_child(arms)

	var length := float(spec["arm_length"])
	var thickness := float(spec.get("arm_thickness", 0.35))
	var count := maxi(int(spec.get("arms", 1)), 1)

	for arm in range(count):
		var holder := Node3D.new()
		holder.rotation = Vector3(0.0, TAU * float(arm) / float(count), 0.0)
		arms.add_child(holder)

		var bar := MeshInstance3D.new()
		var bar_box := BoxMesh.new()
		bar_box.size = Vector3(length - hub_radius, thickness, thickness)
		bar.mesh = bar_box
		bar.position = Vector3(hub_radius + (length - hub_radius) * 0.5, 0.0, 0.0)
		bar.material_override = WoTextures.surface(role, true)
		holder.add_child(bar)

		# A soft end, which is what makes an arm read as something that hits rather than
		# something that cuts.
		var tip := MeshInstance3D.new()
		var tip_sphere := SphereMesh.new()
		tip_sphere.radius = thickness * 0.9
		tip_sphere.height = thickness * 1.8
		tip.mesh = tip_sphere
		tip.position = Vector3(length, 0.0, 0.0)
		tip.material_override = WoTextures.surface(role, true)
		holder.add_child(tip)

	return root


func _pendulum(spec: Dictionary, role: WoTextures.Role) -> Node3D:
	var root := Node3D.new()
	root.transform = Transform3D(_yaw_basis(float(spec["yaw"])), spec["pivot"])

	var length := float(spec["length"])
	var radius := float(spec["radius"])
	var swing := float(spec["swing"])

	# The gantry it hangs from, drawn across the swing so a player can see where it reaches.
	var reach := sin(deg_to_rad(minf(absf(swing), 89.0))) * length + radius
	_add_box(root, Vector3(reach * 2.0 + 1.0, 0.35, 0.35), WoTextures.Role.PILLAR, false, false)

	var arm := Node3D.new()
	arm.name = "Arm"
	root.add_child(arm)

	var rod := MeshInstance3D.new()
	var rod_mesh := CylinderMesh.new()
	rod_mesh.top_radius = 0.06
	rod_mesh.bottom_radius = 0.06
	rod_mesh.height = length
	rod.mesh = rod_mesh
	rod.position = Vector3(0.0, -length * 0.5, 0.0)
	rod.material_override = WoTextures.surface(WoTextures.Role.PILLAR, true)
	arm.add_child(rod)

	var ball := MeshInstance3D.new()
	var ball_mesh := SphereMesh.new()
	ball_mesh.radius = radius
	ball_mesh.height = radius * 2.0
	ball.mesh = ball_mesh
	ball.position = Vector3(0.0, -length, 0.0)
	ball.material_override = WoTextures.surface(role, true)
	arm.add_child(ball)

	return root


func _pusher(spec: Dictionary, role: WoTextures.Role) -> Node3D:
	var root := Node3D.new()
	var ram := Node3D.new()
	ram.name = "Ram"
	root.add_child(ram)
	_add_box(ram, spec["size"], role, true, false)
	return root


## The start pad, and the gate across its front that the countdown holds closed.
func _build_start() -> void:
	var start: Dictionary = doc["start"]
	var at: Vector3 = start["at"]
	var size: Vector2 = start["size"]
	var basis := _yaw_basis(float(start["yaw"]))

	var pad := StaticBody3D.new()
	pad.name = "Start"
	pad.transform = Transform3D(basis, at - Vector3(0.0, 0.5, 0.0))
	_add_box(pad, Vector3(size.x, 1.0, size.y), WoTextures.Role.SAFE, false, true)
	add_child(pad)
	_put_on_world_layer(pad)

	# Across the front edge, which is -Z in the pad's own frame: yaw 0 faces -Z, and the
	# course runs the way the players are facing.
	_gate = _animatable()
	_gate.name = "Gate"
	_gate_rest = Transform3D(basis, at + basis * Vector3(0.0, 1.4, -size.y * 0.5 - 0.2))
	_add_box(_gate, Vector3(size.x + 0.4, 2.8, 0.3), WoTextures.Role.CANNON, false, true)
	add_child(_gate)
	_put_on_world_layer(_gate)

	# And walls down both sides and across the back, so the countdown cannot be spent
	# walking off the pad into the water.
	for side in [-1.0, 1.0]:
		var wall := StaticBody3D.new()
		wall.transform = Transform3D(basis, at + basis * Vector3(side * (size.x * 0.5 + 0.2), 0.7, 0.0))
		_add_box(wall, Vector3(0.3, 1.4, size.y), WoTextures.Role.PILLAR, false, true)
		add_child(wall)
		_put_on_world_layer(wall)

	var back := StaticBody3D.new()
	back.transform = Transform3D(basis, at + basis * Vector3(0.0, 0.7, size.y * 0.5 + 0.2))
	_add_box(back, Vector3(size.x + 0.7, 1.4, 0.3), WoTextures.Role.PILLAR, false, true)
	add_child(back)
	_put_on_world_layer(back)

	_place_gate()


func _place_gate() -> void:
	if _gate == null:
		return

	var at := _gate_rest

	if not gate_closed:
		at.origin -= Vector3(0.0, GATE_DROP, 0.0)

	_place(_gate, at)


## Flags at every checkpoint and an arch over the finish. Meshes only: what counts is the
## volume, which [method checkpoint_at] and [method in_finish] measure.
func _build_markers() -> void:
	for index in range((doc["checkpoints"] as Array).size()):
		var checkpoint: Dictionary = doc["checkpoints"][index]
		_arch(checkpoint["at"], checkpoint["size"], float(checkpoint["yaw"]), WoTextures.Role.SAFE, 0.25)

	var finish: Dictionary = doc["finish"]
	_arch(finish["at"], finish["size"], float(finish["yaw"]), WoTextures.Role.CANNON, 0.5)


func _arch(at: Vector3, size: Vector3, yaw: float, role: WoTextures.Role, thickness: float) -> void:
	var basis := _yaw_basis(yaw)
	var arch := Node3D.new()
	arch.name = "Arch"
	arch.transform = Transform3D(basis, at)
	add_child(arch)

	var height := maxf(size.y, 2.5)

	for side in [-1.0, 1.0]:
		_add_box(arch, Vector3(thickness, height, thickness), WoTextures.Role.PILLAR, false, false,
			Vector3(side * size.x * 0.5, height * 0.5 - 0.0, 0.0))

	_add_box(arch, Vector3(size.x + thickness, thickness * 1.6, thickness), role, false, false,
		Vector3(0.0, height, 0.0))


## Where everybody who did not finish watches the final death from: a walled box they cannot
## leave and nobody can reach.
func _build_gallery() -> void:
	var gallery: Dictionary = doc["gallery"]
	var at: Vector3 = gallery["at"]
	var size: Vector2 = gallery["size"]

	var floor_body := StaticBody3D.new()
	floor_body.name = "Gallery"
	floor_body.position = at - Vector3(0.0, 0.5, 0.0)
	_add_box(floor_body, Vector3(size.x, 1.0, size.y), WoTextures.Role.SAFE, false, true)
	add_child(floor_body)
	_put_on_world_layer(floor_body)

	# Glass, in effect: walls tall enough that nobody jumps out, thin enough to watch over
	# from a step back. Drawn low so they do not block the view; the collider is the tall
	# part.
	var walls := [
		[Vector3(0.0, 2.0, -size.y * 0.5), Vector3(size.x, 4.0, 0.2)],
		[Vector3(0.0, 2.0, size.y * 0.5), Vector3(size.x, 4.0, 0.2)],
		[Vector3(-size.x * 0.5, 2.0, 0.0), Vector3(0.2, 4.0, size.y)],
		[Vector3(size.x * 0.5, 2.0, 0.0), Vector3(0.2, 4.0, size.y)],
	]

	for wall: Array in walls:
		var body := StaticBody3D.new()
		body.position = at + (wall[0] as Vector3)
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = wall[1]
		shape.shape = box
		body.add_child(shape)
		_add_box(body, Vector3((wall[1] as Vector3).x, 0.9, (wall[1] as Vector3).z),
			WoTextures.Role.PILLAR, false, false, Vector3(0.0, -1.55, 0.0))
		add_child(body)
		_put_on_world_layer(body)


## The sky, the sun and the water. Client side.
func _build_world() -> void:
	var theme: Dictionary = doc.get("theme", {})

	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation = Vector3(deg_to_rad(-52.0), deg_to_rad(34.0), 0.0)
	# mg-smash-copter's number, measured under `gl_compatibility`: higher than this and every
	# prototype surface comes back within a few percent of white, which on a course is every
	# gap reading as floor.
	sun.light_energy = 0.82
	sun.light_color = theme.get("sun", Color(1.0, 0.96, 0.88))
	sun.shadow_enabled = true
	add_child(sun)

	var env := Environment.new()
	env.background_mode = Environment.BG_SKY

	var sky := Sky.new()
	var material := ProceduralSkyMaterial.new()
	material.sky_top_color = theme.get("sky", Color(0.52, 0.72, 0.92))
	material.sky_horizon_color = theme.get("horizon", Color(0.82, 0.88, 0.94))
	material.ground_bottom_color = (theme.get("water", Color(0.16, 0.42, 0.62)) as Color).darkened(0.4)
	material.ground_horizon_color = theme.get("horizon", Color(0.82, 0.88, 0.94))
	sky.sky_material = material
	env.sky = sky

	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.36
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure = 0.64
	env.fog_enabled = true
	env.fog_light_color = theme.get("horizon", Color(0.82, 0.88, 0.94))
	env.fog_density = 0.0016

	var world_env := WorldEnvironment.new()
	world_env.name = "Environment"
	world_env.environment = env
	add_child(world_env)

	# The water: what everybody who falls lands in. A plane, drawn only; the fall is a height
	# comparison in [WoGame], for the reason mg-smash-copter gives — a trigger volume can be
	# stepped over between two ticks by something falling fast enough.
	var water := MeshInstance3D.new()
	water.name = "Water"
	var plane := PlaneMesh.new()
	plane.size = Vector2(1600.0, 1600.0)
	water.mesh = plane
	# Darker than the theme's colour and barely glossy. The first render had it at 0.18
	# roughness, and a glossy plane under a blue sky IS the sky: the horizon vanished and a
	# course read as floating in a blue void, which is the one thing the water is there to
	# say otherwise.
	var water_material := StandardMaterial3D.new()
	water_material.albedo_color = (theme.get("water", Color(0.16, 0.42, 0.62)) as Color).darkened(0.35)
	water_material.roughness = 0.55
	water_material.metallic = 0.0
	water.material_override = water_material
	water.position = Vector3(0.0, water_height() - 0.4, 0.0)
	add_child(water)


# --- Where everything is ------------------------------------------------------

## Poses every moving piece at [param tick]. Idempotent per tick.
func pose_at(tick: int) -> void:
	if tick == _posed_tick:
		return

	pose_at_time(float(tick) / float(maxi(tick_rate, 1)))
	_posed_tick = tick


## Poses every moving piece at [param seconds]. What a client draws between two ticks.
##
## [b]Forgets which tick it was posed at.[/b] A frame posed between ticks N and N+1 has moved
## every collider off tick N, so the next [method pose_at] for N must not take the shortcut —
## or a client's prediction sweeps tick N against tick N-and-a-half.
func pose_at_time(seconds: float) -> void:
	_posed_time = seconds
	_posed_tick = -2147483648

	for piece in pieces:
		if bool(piece["moving"]):
			_pose_piece(piece, seconds)


func _pose_piece(piece: Dictionary, t: float) -> void:
	var node: Node3D = piece["node"]
	var spec: Dictionary = piece["spec"]

	if node == null or not is_instance_valid(node):
		return

	match str(piece["kind"]):
		"mover", "turntable", "roller", "seesaw":
			# Local, and that is world: a course is built at the origin of its world and never
			# moved, which [WoGame] keeps true.
			_place(node, transform_of(piece, t))
		"conveyor":
			var slats := node.get_node_or_null(^"Slats") as Node3D

			if slats != null:
				var size: Vector3 = spec["size"]
				var count := slats.get_child_count()
				var spacing := size.z / float(maxi(count, 1))
				var run := fposmod(float(spec["speed"]) * t, spacing)

				for i in range(count):
					var slat := slats.get_child(i) as Node3D
					var z := fposmod(-size.z * 0.5 + float(i) * spacing - run + size.z * 0.5, size.z) \
						- size.z * 0.5
					slat.position = Vector3(0.0, size.y * 0.5 + 0.03, z)
		"tiles":
			var index := 0

			for child in node.get_children():
				var tile := child as Node3D

				if tile == null:
					continue

				var rest: Vector3 = tile.get_meta(&"rest", Vector3.ZERO)
				_place(tile, Transform3D(tile.transform.basis,
					rest - Vector3(0.0, TILE_DROP if tile_down(piece, index, t) else 0.0, 0.0)))
				_warn_tile(tile, tile_warning(spec, index, t), t)
				index += 1
		"spinner":
			var arms := node.get_node_or_null(^"Arms") as Node3D

			if arms != null:
				arms.rotation = Vector3(0.0, spinner_angle(spec, t), 0.0)
		"pendulum":
			var arm := node.get_node_or_null(^"Arm") as Node3D

			if arm != null:
				arm.rotation = Vector3(0.0, 0.0, pendulum_angle(spec, t))
		"pusher":
			var ram := node.get_node_or_null(^"Ram") as Node3D

			if ram != null:
				ram.transform = pusher_transform(spec, t)


## Where a carrier is at [param t], as a world transform. The one formula per kind.
func transform_of(piece: Dictionary, t: float) -> Transform3D:
	var spec: Dictionary = piece["spec"]
	var yaw := _yaw_basis(float(spec.get("yaw", 0.0)))

	match str(piece["kind"]):
		"mover":
			var from: Vector3 = spec["from"]
			var to: Vector3 = spec["to"]
			return Transform3D(yaw, from.lerp(to, mover_fraction(spec, t)))
		"turntable":
			var angle := deg_to_rad(float(spec.get("phase", 0.0)) + float(spec["speed"]) * t)
			return Transform3D(yaw * Basis(Vector3.UP, angle), spec["at"])
		"roller":
			var angle := deg_to_rad(float(spec.get("phase", 0.0)) + float(spec["speed"]) * t)
			return Transform3D(yaw * Basis(Vector3.RIGHT, angle), spec["at"])
		"seesaw":
			return Transform3D(yaw * Basis(Vector3.RIGHT, seesaw_angle(spec, t)), spec["at"])
		_:
			return (piece["node"] as Node3D).transform


## How far along its track a mover is, 0 at `from` and 1 at `to`. Eased at both ends, so a
## player riding one is not thrown off by a reversal at full speed.
static func mover_fraction(spec: Dictionary, t: float) -> float:
	var cycle := t / float(spec["period"]) + float(spec.get("phase", 0.0))
	return 0.5 - 0.5 * cos(TAU * cycle)


static func seesaw_angle(spec: Dictionary, t: float) -> float:
	var cycle := t / float(spec["period"]) + float(spec.get("phase", 0.0))
	return deg_to_rad(float(spec["amplitude"])) * sin(TAU * cycle)


static func spinner_angle(spec: Dictionary, t: float) -> float:
	return deg_to_rad(float(spec.get("phase", 0.0)) + float(spec["speed"]) * t)


static func pendulum_angle(spec: Dictionary, t: float) -> float:
	var cycle := t / float(spec["period"]) + float(spec.get("phase", 0.0))
	return deg_to_rad(float(spec["swing"])) * sin(TAU * cycle)


## How far out a pusher's ram is, 0 at rest and 1 at full reach.
##
## [b]Fast out, a hold, slower back, and a rest — and the rest is the part a player uses.[/b]
## A ram that went in and out on a sine would be a hazard with no gap to time; this one is
## home for the part of its period after `duty` plus its return, which is the window a player
## runs through.
static func pusher_extension(spec: Dictionary, t: float) -> float:
	var u := fposmod(t / float(spec["period"]) + float(spec.get("phase", 0.0)), 1.0)
	var duty := clampf(float(spec.get("duty", 0.35)), 0.1, 0.8)
	var out_time := 0.08

	if u < out_time:
		return smoothstep(0.0, 1.0, u / out_time)

	if u < duty:
		return 1.0

	var back := minf(0.2, 1.0 - duty)

	if u < duty + back:
		return 1.0 - smoothstep(0.0, 1.0, (u - duty) / back)

	return 0.0


## The ram's transform at [param t], in the course's frame. The ram travels along its own
## -Z, which is the way `yaw` faces.
static func pusher_transform(spec: Dictionary, t: float) -> Transform3D:
	var basis := _yaw_basis(float(spec.get("yaw", 0.0)))
	var out := pusher_extension(spec, t) * float(spec["reach"])
	return Transform3D(basis, (spec["at"] as Vector3) + basis * Vector3(0.0, 0.0, -out))


## Whether tile [param index] of a tiles piece is gone at [param t].
##
## Each tile has its own offset into the cycle, drawn from the piece's seed by a hash rather
## than a random stream, so it is the same on every machine and does not depend on how many
## times anything else has drawn.
static func tile_down(piece: Dictionary, index: int, t: float) -> bool:
	return tile_cycle(piece["spec"], index, t) < float((piece["spec"] as Dictionary)["down"])


## Where tile [param index] is in its cycle, 0..1. It drops at 0 and comes back at `down`.
static func tile_cycle(spec: Dictionary, index: int, t: float) -> float:
	var seed := int(spec.get("seed", 1))
	var offset := float(_mix(seed * 7919 + index * 104729) % 1000) / 1000.0
	return fposmod(t / float(spec["period"]) + offset, 1.0)


## How close tile [param index] is to dropping, 0 (not soon) to 1 (now).
##
## [b]A tile that drops with no tell is a coin toss, not an obstacle.[/b] The schedule is a
## hash of the tile's index, which nobody can read off a floor; what a player CAN read is a
## tile shaking and turning the hazard colour for the last [constant TILE_WARN_SECONDS]
## before it goes. A function of the tick like everything else here, so every client shows
## the same warning at the same moment without being told.
static func tile_warning(spec: Dictionary, index: int, t: float) -> float:
	var period := float(spec["period"])
	var warn := clampf(TILE_WARN_SECONDS / period, 0.0, 0.5)
	var cycle := tile_cycle(spec, index, t)

	if cycle < float(spec["down"]) or cycle < 1.0 - warn:
		return 0.0

	return (cycle - (1.0 - warn)) / maxf(warn, 0.0001)


## The tell, on the MESH only: the collider stays put, so a warned tile is still exactly as
## solid as it was and nobody is shaken off it by the warning itself.
func _warn_tile(tile: Node3D, warning: float, t: float) -> void:
	var mesh: MeshInstance3D = null

	for child in tile.get_children():
		if child is MeshInstance3D:
			mesh = child
			break

	if mesh == null:
		return

	if warning <= 0.0:
		mesh.position = Vector3.ZERO
		if mesh.get_meta(&"warned", false):
			mesh.material_override = mesh.get_meta(&"rest_material")
			mesh.set_meta(&"warned", false)
		return

	var shake := 0.04 + 0.06 * warning
	mesh.position = Vector3(sin(t * 61.0) * shake, 0.0, cos(t * 53.0) * shake)

	if not mesh.get_meta(&"warned", false):
		mesh.set_meta(&"rest_material", mesh.material_override)
		mesh.material_override = WoTextures.surface(WoTextures.Role.HAZARD, true)
		mesh.set_meta(&"warned", true)


static func _mix(value: int) -> int:
	# A small integer hash, the same on every platform: no `hash()`, whose output on a
	# built-in is not promised to be stable across engine versions.
	var x := (value ^ 0x5bd1e995) & 0x7fffffff
	x = ((x >> 15) ^ x) * 0x2c1b3c6d & 0x7fffffff
	x = ((x >> 12) ^ x) * 0x297a2d39 & 0x7fffffff
	return ((x >> 15) ^ x) & 0x7fffffff


# --- What a player's movement asks ----------------------------------------------

## How far whatever [param ground_id] is moves a point at [param at] between [param tick]
## and the next one. Zero for anything that is not a carrier.
##
## [b]The exact displacement, not a velocity times a step.[/b] A point on a turntable moves
## along an arc; a velocity taken at the start of the tick moves it along the tangent, which
## is outward by a little every tick, and a player standing still on a turntable spirals off
## it. `pose(t + dt) * pose(t)⁻¹` applied to the point is the arc.
func carry(ground_id: int, at: Vector3, tick: int) -> Vector3:
	var found: Variant = _by_collider.get(ground_id)

	if found == null:
		return Vector3.ZERO

	var piece: Dictionary = pieces[int((found as Array)[0])]

	if not bool(piece["carrier"]):
		return Vector3.ZERO

	var dt := 1.0 / float(maxi(tick_rate, 1))
	var t := float(tick) * dt

	if str(piece["kind"]) == "conveyor":
		var spec: Dictionary = piece["spec"]
		return _conveyor_basis(spec) * Vector3(0.0, 0.0, -float(spec["speed"]) * dt)

	var now := transform_of(piece, t)
	var next := transform_of(piece, t + dt)
	return (next * now.affine_inverse()) * at - at


## Whether whatever [param ground_id] is moves whoever stands on it.
func carries(ground_id: int) -> bool:
	var found: Variant = _by_collider.get(ground_id)
	return found != null and bool(pieces[int((found as Array)[0])]["carrier"])


## The upward speed a bouncer under [param ground_id] gives, or 0.
func bounce(ground_id: int) -> float:
	var found: Variant = _by_collider.get(ground_id)

	if found == null:
		return 0.0

	var piece: Dictionary = pieces[int((found as Array)[0])]

	if str(piece["kind"]) != "bouncer":
		return 0.0

	return float((piece["spec"] as Dictionary)["power"])


## The velocity an obstacle throws a player standing at [param feet] with, on [param tick],
## or zero if nothing is touching them.
##
## [param crouched] shortens the capsule, which is what lets a player duck under a high arm.
## [param limits] is `[minimum speed, maximum speed, lift]`, from the configuration.
func knock(feet: Vector3, crouched: bool, tick: int, limits: Vector3) -> Vector3:
	var t := float(tick) / float(maxi(tick_rate, 1))
	var top := feet + Vector3(0.0, (PLAYER_CROUCHED if crouched else PLAYER_HEIGHT) - PLAYER_RADIUS, 0.0)
	var bottom := feet + Vector3(0.0, PLAYER_RADIUS, 0.0)

	for piece in pieces:
		if not bool(piece["hazard"]):
			continue

		var thrown := Vector3.ZERO

		match str(piece["kind"]):
			"spinner":
				thrown = _knock_spinner(piece, bottom, top, t)
			"pendulum":
				thrown = _knock_pendulum(piece, bottom, top, t)
			"pusher":
				thrown = _knock_pusher(piece, bottom, top, t)

		if thrown != Vector3.ZERO:
			var flat := Vector3(thrown.x, 0.0, thrown.z)
			var speed := clampf(flat.length(), limits.x, limits.y)
			flat = flat.normalized() * speed if flat.length() > 0.001 else Vector3.ZERO
			return Vector3(flat.x, maxf(thrown.y, limits.z), flat.z)

	return Vector3.ZERO


func _knock_spinner(piece: Dictionary, bottom: Vector3, top: Vector3, t: float) -> Vector3:
	var spec: Dictionary = piece["spec"]
	var root: Node3D = piece["node"]
	var arm_height := float(spec.get("arm_height", 1.0))
	var length := float(spec["arm_length"])
	var hub_radius := float(spec.get("hub_radius", 0.6))
	var thickness := float(spec.get("arm_thickness", 0.35))
	var count := maxi(int(spec.get("arms", 1)), 1)
	var angle := spinner_angle(spec, t)
	var omega := deg_to_rad(float(spec["speed"]))
	var frame := root.transform
	var hub := frame * Vector3(0.0, arm_height, 0.0)

	for arm in range(count):
		var heading := Basis(Vector3.UP, angle + TAU * float(arm) / float(count))
		var tip := frame * (Vector3(0.0, arm_height, 0.0) + heading * Vector3(length, 0.0, 0.0))
		var start := hub + (tip - hub).normalized() * hub_radius
		var closest := _segments(start, tip, bottom, top)

		if closest[2] > thickness * 0.5 + PLAYER_RADIUS:
			continue

		# The arm's own speed where it touched them: tangent to the circle at that radius,
		# in the direction it turns.
		var on_arm: Vector3 = closest[0]
		var radial := on_arm - hub
		radial.y = 0.0
		var tangent := Vector3.UP.cross(radial).normalized() * signf(omega)
		var push := tangent * absf(omega) * radial.length() * 1.25
		# And a little outward, so the knock carries somebody off the side of the platform
		# rather than along the arm's own path, where the next arm meets them.
		push += radial.normalized() * 2.0
		return push

	return Vector3.ZERO


func _knock_pendulum(piece: Dictionary, bottom: Vector3, top: Vector3, t: float) -> Vector3:
	var spec: Dictionary = piece["spec"]
	var frame := Transform3D(_yaw_basis(float(spec.get("yaw", 0.0))), spec["pivot"])
	var length := float(spec["length"])
	var radius := float(spec["radius"])
	var angle := pendulum_angle(spec, t)
	var centre := frame * (Basis(Vector3.BACK, angle) * Vector3(0.0, -length, 0.0))
	var distance := _point_segment(centre, bottom, top)

	if distance > radius + PLAYER_RADIUS:
		return Vector3.ZERO

	# The ball's velocity, from the derivative of the swing: the speed of a point at the end
	# of the rod is the angular rate times the length, along the tangent of the arc.
	var dt := 0.001
	var ahead := frame * (Basis(Vector3.BACK, pendulum_angle(spec, t + dt)) * Vector3(0.0, -length, 0.0))
	var velocity := (ahead - centre) / dt
	velocity.y = 0.0

	if velocity.length() < 0.5:
		# At the top of its swing it is barely moving; it still shoves somebody out of the
		# way it came, which is the direction from the ball to them.
		var away := ((bottom + top) * 0.5) - centre
		away.y = 0.0
		return away.normalized() * 3.0

	return velocity * 1.3


func _knock_pusher(piece: Dictionary, bottom: Vector3, top: Vector3, t: float) -> Vector3:
	var spec: Dictionary = piece["spec"]
	var root: Node3D = piece["node"]
	var frame := root.transform * pusher_transform(spec, t)
	var half := (spec["size"] as Vector3) * 0.5
	var inverse := frame.affine_inverse()

	var hit := false

	for step in range(5):
		var point := bottom.lerp(top, float(step) / 4.0)
		var local := inverse * point
		var clamped := Vector3(
			clampf(local.x, -half.x, half.x),
			clampf(local.y, -half.y, half.y),
			clampf(local.z, -half.z, half.z)
		)

		if local.distance_to(clamped) <= PLAYER_RADIUS:
			hit = true
			break

	if not hit:
		return Vector3.ZERO

	var forward := frame.basis * Vector3(0.0, 0.0, -1.0)
	var dt := 0.02
	var moving := (pusher_extension(spec, t + dt) - pusher_extension(spec, t)) / dt * float(spec["reach"])

	if moving > 0.5:
		return forward * maxf(moving * 1.2, 14.0)

	# Out and holding, or going home: it still will not let anybody stand inside it.
	return forward * 4.0


## The closest points between two segments, and the distance between them.
##
## Returns `[point on the first, point on the second, distance]`. The standard clamped
## solution; written out rather than taken from `Geometry3D` so the arithmetic is the same
## on every build this runs on.
static func _segments(p1: Vector3, q1: Vector3, p2: Vector3, q2: Vector3) -> Array:
	var d1 := q1 - p1
	var d2 := q2 - p2
	var r := p1 - p2
	var a := d1.dot(d1)
	var e := d2.dot(d2)
	var f := d2.dot(r)
	var s := 0.0
	var u := 0.0

	if a <= 0.000001 and e <= 0.000001:
		return [p1, p2, p1.distance_to(p2)]

	if a <= 0.000001:
		u = clampf(f / e, 0.0, 1.0)
	else:
		var c := d1.dot(r)

		if e <= 0.000001:
			s = clampf(-c / a, 0.0, 1.0)
		else:
			var b := d1.dot(d2)
			var denom := a * e - b * b
			s = clampf((b * f - c * e) / denom, 0.0, 1.0) if denom > 0.000001 else 0.0
			u = (b * s + f) / e

			if u < 0.0:
				u = 0.0
				s = clampf(-c / a, 0.0, 1.0)
			elif u > 1.0:
				u = 1.0
				s = clampf((b - c) / a, 0.0, 1.0)

	var c1 := p1 + d1 * s
	var c2 := p2 + d2 * u
	return [c1, c2, c1.distance_to(c2)]


static func _point_segment(point: Vector3, a: Vector3, b: Vector3) -> float:
	var ab := b - a
	var length := ab.length_squared()

	if length <= 0.000001:
		return point.distance_to(a)

	var s := clampf((point - a).dot(ab) / length, 0.0, 1.0)
	return point.distance_to(a + ab * s)


# --- What a stand-in asks -------------------------------------------------------

## Whether an arm at head height — one to duck, not jump — turns within [param radius] of
## [param at]. Only a spinner is ducked: a pendulum's ball sweeps up through crouching height
## at the ends of its swing, so a duck under one is a slow crawl into it.
func high_arm_near(at: Vector3, radius: float) -> bool:
	for piece in pieces:
		if str(piece["kind"]) != "spinner":
			continue

		var spec: Dictionary = piece["spec"]

		if float(spec.get("arm_height", 1.0)) < 1.1:
			continue

		var hub: Vector3 = spec["at"]

		if Vector2(at.x - hub.x, at.z - hub.z).length() <= float(spec["arm_length"]) + radius:
			return true

	return false


## Whether running straight from [param from] to [param to] at [param speed], starting on
## [param tick], meets no hazard on the way.
##
## [b]The answer is exact, and that is what an obstacle being a function of the tick buys.[/b]
## A bot does not guess when an arm will come round: it asks [method knock] about every point
## of the run at the tick it will be there, the same question its own movement will be asked
## when it gets there. A course a stand-in cannot cross is therefore a course whose timing
## really has no window, which is a finding about the course.
func path_clear(from: Vector3, to: Vector3, tick: int, speed: float, margin_seconds: float = 0.5) -> bool:
	# Four fifths of the run speed: whoever asks is standing still, and the first few metres
	# are spent getting up to speed.
	speed *= 0.8
	var distance := Vector2(to.x - from.x, to.z - from.z).length()
	var seconds := distance / maxf(speed, 0.5) + margin_seconds
	var steps := maxi(int(seconds * 16.0), 1)
	var ticks_per_step := float(tick_rate) / 16.0
	var limits := Vector3(1.0, 1.0, 1.0)

	for step in range(steps + 1):
		var along := clampf(float(step) / 16.0 * speed / maxf(distance, 0.01), 0.0, 1.0)
		var at := from.lerp(to, along)

		if knock(at, false, tick + int(float(step) * ticks_per_step), limits) != Vector3.ZERO:
			return false

	return true


## Whether something solid is under [param point] on [param tick]: what a stand-in asks
## before jumping for a mover or a tile.
func supported(point: Vector3, tick: int) -> bool:
	var t := float(tick) / float(maxi(tick_rate, 1))

	for piece in pieces:
		var spec: Dictionary = piece["spec"]

		match str(piece["kind"]):
			"box", "ramp", "bouncer", "conveyor", "mover", "seesaw":
				var frame: Transform3D = transform_of(piece, t) if bool(piece["moving"]) else (piece["node"] as Node3D).transform
				var local := frame.affine_inverse() * point
				var half := (spec["size"] as Vector3) * 0.5

				if absf(local.x) <= half.x - 0.3 and absf(local.z) <= half.z - 0.3 and local.y > -1.0 and local.y < 3.0:
					return true
			"turntable", "cylinder":
				var at: Vector3 = spec["at"]

				if Vector2(point.x - at.x, point.z - at.z).length() <= float(spec["radius"]) - 0.4 \
						and point.y > at.y - 1.0 and point.y < at.y + 3.0:
					return true
			"ball":
				var at: Vector3 = spec["at"]

				if Vector2(point.x - at.x, point.z - at.z).length() <= float(spec["radius"]) * 0.45:
					return true
			"tiles":
				var root: Node3D = piece["node"]
				var local := root.transform.affine_inverse() * point
				var cols := int(spec["cols"])
				var rows := int(spec["rows"])
				var pitch := float(spec["tile"]) + float(spec.get("gap", 0.25))
				var col := int(roundf(local.x / pitch + float(cols - 1) * 0.5))
				var row := int(roundf(local.z / pitch + float(rows - 1) * 0.5))

				if col >= 0 and col < cols and row >= 0 and row < rows and absf(local.y) < 3.0:
					if not tile_down(piece, row * cols + col, t):
						return true

	return false


# --- The course's own facts -----------------------------------------------------

func water_height() -> float:
	if is_arena():
		return float(doc.get("kill_height", -10.0))

	return float(doc.get("water_height", -8.0))


func checkpoint_count() -> int:
	return (doc.get("checkpoints", []) as Array).size()


## Which checkpoint volume [param feet] is inside, or -1.
func checkpoint_at(feet: Vector3) -> int:
	var probe := feet + Vector3(0.0, 0.9, 0.0)
	var checkpoints: Array = doc.get("checkpoints", [])

	for index in range(checkpoints.size()):
		var checkpoint: Dictionary = checkpoints[index]

		if _inside(probe, checkpoint["at"], checkpoint["size"], float(checkpoint["yaw"])):
			return index

	return -1


func in_finish(feet: Vector3) -> bool:
	if not is_course():
		return false

	var finish: Dictionary = doc["finish"]
	return _inside(feet + Vector3(0.0, 0.9, 0.0), finish["at"], finish["size"], float(finish["yaw"]))


## Whether [param point] is inside a box whose BOTTOM-centre is [param at].
##
## Bottom-centre for a gate, because a mapper places a checkpoint on the floor a player
## crosses it on, and the volume rises from there.
static func _inside(point: Vector3, at: Vector3, size: Vector3, yaw: float) -> bool:
	var local := _yaw_basis(yaw).inverse() * (point - at)
	return absf(local.x) <= size.x * 0.5 and local.y >= -0.5 and local.y <= size.y \
		and absf(local.z) <= size.z * 0.5


## Where somebody restarts from after falling: the checkpoint they last crossed, or the start.
## Returns `[position, yaw]`.
func respawn_point(checkpoint: int, seat: int = 0) -> Array:
	var checkpoints: Array = doc.get("checkpoints", [])

	if checkpoint >= 0 and checkpoint < checkpoints.size():
		var entry: Dictionary = checkpoints[checkpoint]
		var basis := _yaw_basis(float(entry["yaw"]))
		var spread := _spread(seat, (entry["size"] as Vector3).x * 0.6)
		return [(entry["at"] as Vector3) + basis * spread + Vector3(0.0, 0.2, 0.0), float(entry["yaw"])]

	# Full rows, as a joiner gets: a restart that centred its seat on a row of ONE put the
	# fifth faller six metres to the side, off the pad's edge where the run-out is narrower.
	return start_spot(seat, 1000)


## Where seat [param seat] of [param of] stands on the start pad.
##
## Rows across the pad from the front, a metre and a half apart, so a full server of
## twenty-four is four rows of six on a ten metre pad and nobody is placed inside anybody.
func start_spot(seat: int, of: int) -> Array:
	var start: Dictionary = doc.get("start", {})

	if start.is_empty():
		return [Vector3.ZERO, 0.0]

	var size: Vector2 = start["size"]
	var basis := _yaw_basis(float(start["yaw"]))
	var per_row := maxi(int((size.x - 1.0) / 1.5), 1)
	var row := seat / per_row
	var column := seat % per_row
	var in_row := mini(per_row, of - row * per_row)
	var x := (float(column) - float(maxi(in_row, 1) - 1) * 0.5) * 1.5
	# Two and a half metres back from the gate for the front row: closer, and the gate is the
	# whole of a first-person view for the countdown.
	var z := -size.y * 0.5 + 2.5 + float(row) * 1.5
	z = minf(z, size.y * 0.5 - 0.8)
	return [(start["at"] as Vector3) + basis * Vector3(x, 0.2, z), float(start["yaw"])]


## Where a finisher waits: the lounge, spread so two people are not put inside each other.
func lounge_spot(seat: int) -> Array:
	var finish: Dictionary = doc.get("finish", {})

	if finish.is_empty():
		return [Vector3.ZERO, 0.0]

	return [(finish["lounge"] as Vector3) + _spread(seat, 3.0) + Vector3(0.0, 0.3, 0.0),
		float(finish["yaw"])]


static func _spread(seat: int, width: float) -> Vector3:
	if seat <= 0:
		return Vector3.ZERO

	# A small spiral, in a fixed order: seat 1 to the right, 2 to the left, then a ring.
	var angle := float(seat) * 2.39996
	var reach := minf(0.9 * sqrt(float(seat)), width * 0.5)
	return Vector3(cos(angle) * reach, 0.0, sin(angle) * reach)


## The route a stand-in follows, as the document gives it.
func route() -> Array:
	return doc.get("route", [])


func spawn_areas() -> Array:
	return doc.get("spawns", [])


func drop_areas() -> Array:
	return doc.get("drops", [])


## A point in the gallery for seat [param seat].
func gallery_spot(seat: int) -> Array:
	var gallery: Dictionary = doc.get("gallery", {})

	if gallery.is_empty():
		return [Vector3(0.0, 50.0, 0.0), 0.0]

	var size: Vector2 = gallery["size"]
	var per_row := maxi(int((size.x - 1.0) / 1.2), 1)
	var x := (float(seat % per_row) - float(per_row - 1) * 0.5) * 1.2
	var z := (float(seat / per_row) - 0.5) * 1.2
	z = clampf(z, -size.y * 0.5 + 0.6, size.y * 0.5 - 0.6)
	return [(gallery["at"] as Vector3) + Vector3(x, 0.2, z), 0.0]


## Roughly where the middle of everything is, and how far it reaches. For an overview camera.
func bounds() -> AABB:
	var box := AABB()
	var first := true

	for piece in pieces:
		var spec: Dictionary = piece["spec"]
		var at: Vector3 = spec.get("at", spec.get("pivot", spec.get("from", Vector3.ZERO)))

		if first:
			box = AABB(at, Vector3.ZERO)
			first = false
		else:
			box = box.expand(at)

		if spec.has("to"):
			box = box.expand(spec["to"])

	return box


func describe() -> Dictionary:
	var hazards := 0
	var carriers := 0

	for piece in pieces:
		if bool(piece["hazard"]):
			hazards += 1
		if bool(piece["carrier"]):
			carriers += 1

	return {
		"id": String(id()),
		"kind": str(doc.get("kind", "-")),
		"name": str(doc.get("name", "-")),
		"pieces": pieces.size(),
		"hazards": hazards,
		"carriers": carriers,
		"checkpoints": checkpoint_count(),
		"gate": "closed" if gate_closed else "open",
		"posed": "%.2f s" % _posed_time,
	}


func describe_lines() -> PackedStringArray:
	var lines := PackedStringArray(["course"])
	var facts := describe()

	for key: String in facts:
		lines.append("  %-12s %s" % [key, facts[key]])

	return lines
