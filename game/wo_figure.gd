extends Node3D

const WoPaths := preload("wo_paths.gd")

## What somebody ELSE looks like: a Kenney blocky character, scaled to the player's hull,
## wearing their side's colour on the torso and turned to where they are looking. Client
## side only; a server never builds one.
##
## [b]This game drew no person at all until 2026-09-24.[/b] Every player's own view was
## first person, and third person showed the platform rather than the player — so nobody had
## needed a body until a networked client, whose other players were drawn as nothing. Their
## node moved, their beacon marked them, and a platform leaned toward a patch of empty deck.
## See `WoPlayer.present_body` for when one is shown.
##
## [b]Top level, and placed by its caller every frame.[/b] The player node is the
## simulation's: on a remote player it is written by the interpolator once a frame, but on
## the local player and on every offline stand-in it moves once a TICK, and a body hung off
## it would step at the tick rate while the camera beside it is blended between ticks. So
## `WoClient.present_frame` hands every body the position this frame draws — the node for a
## remote player, `render_state()` for one this process simulates — and nothing here
## computes one.
##
## [b]A Kenney character rather than primitives,[/b] because the showdown is a gunfight and
## a capsule does not say which way somebody is facing from forty metres; the kit's head,
## arms and a walk cycle do, for 113 KB. One mesh set and six atlases, the ones
## mg-buses-from-hell chose for being people; which one a player wears comes from their id,
## so every client dresses the same person the same way. [b]The side is on the torso[/b], as
## a tint over the atlas: in a game with up to six teams the first thing anybody needs to
## read off a body is whether to shoot it, and the kit paints nobody in a team's colour.
##
## [b]Loaded by path and repainted by hand, for the pack.[/b] A delivered game is mounted
## under `res://dot_cloud/<id>/<version>/`; the model is loaded through [WoPaths.rebase], and
## every surface is given its atlas explicitly rather than trusting the import's own external
## dependency, which records an absolute `res://assets/…` path that does not exist once
## mounted. mg-buses-from-hell shipped a round where every crate's mesh loaded and none of
## their textures did.

const CHANNEL := "wo.figure"

## Rebased where it is defined, like the atlases below: see [method WoPaths.rebase].
static var MODEL := WoPaths.rebase("res://assets/kenney/characters/character-a.glb")

## Six ordinary people. Every Blocky Character carries byte-identical geometry and UVs, so
## the variety is a texture and nothing else — vendoring six GLBs would be six copies of one.
static var ATLASES: Array[String] = [
	WoPaths.rebase("res://assets/kenney/characters/Textures/texture-a.png"),
	WoPaths.rebase("res://assets/kenney/characters/Textures/texture-b.png"),
	WoPaths.rebase("res://assets/kenney/characters/Textures/texture-c.png"),
	WoPaths.rebase("res://assets/kenney/characters/Textures/texture-e.png"),
	WoPaths.rebase("res://assets/kenney/characters/Textures/texture-f.png"),
	WoPaths.rebase("res://assets/kenney/characters/Textures/texture-k.png"),
]

## How much of the side's colour goes on the torso. Enough to read at the far corner of the
## ring; not so much that the atlas under it becomes a flat block.
const TEAM_TINT := 0.62

## Ground speeds, in metres a second, at which the body starts walking and starts running.
const WALK_FROM := 0.4
const RUN_FROM := 3.6

## Which atlas this figure wears, and the side colour on it. Read by the suite.
var atlas: String = ""
var team_colour: Color = Color.WHITE

## Whether the Kenney model loaded, or the capsule fallback is standing in for it.
var from_art: bool = false

## The clip playing, for the suite and for `describe()`.
var clip: StringName = &""

## The weapon this figure is drawn holding, by id; empty for empty hands. Read by the suite.
var holding: StringName = &""

## The gun in the hand. Built the first time this figure holds anything; see [method hold].
var held: ZeeWorldModel = null

var _model: Node3D = null
var _anim: AnimationPlayer = null
var _arm: Node3D = null
var _hand: Node3D = null
var _scale_by: float = 1.0
var _posed_at_usec: int = -1


func _init() -> void:
	# The caller places it; see the class note.
	top_level = true


## Builds the figure to stand [param height] metres tall, feet at this node's origin.
##
## [b]Measured, not a constant.[/b] A Blocky Character is 2.7 m; a figure at its own size is
## half again a player's hull and would stand with its head in the underside of a chopper.
func build(height: float, atlas_path: String, colour: Color) -> void:
	atlas = atlas_path
	team_colour = colour
	clip = &""
	_anim = null
	_arm = null
	# The hand and the gun in it hung off the old model and go with it; [method hold] builds
	# them again on the next frame, from [member holding], which outlives a rebuild.
	_hand = null
	held = null
	_posed_at_usec = -1

	if _model != null:
		_model.queue_free()
		_model = null

	var scene: Variant = load(MODEL)

	if scene is PackedScene:
		_model = (scene as PackedScene).instantiate() as Node3D

	if _model == null:
		# A capsule rather than nothing. An invisible player is the bug this file exists to
		# end; a grey one is a player whose art did not ship, which is a lesser thing.
		DotLog.warn(CHANNEL, "no character model; drawing a capsule", {
			"path": MODEL,
		})
		_model = _capsule(height, colour)
		add_child(_model)
		from_art = false
		return

	add_child(_model)
	from_art = true

	var bounds := _bounds(_model, Transform3D.IDENTITY)
	var scale_by := height / maxf(bounds.size.y, 0.01)

	# [b]Turned round, because the kit faces +Z and this family's forward is -Z.[/b]
	# mg-buses-from-hell's bus chased people cab-last until a render showed it.
	_model.basis = Basis(Vector3.UP, PI).scaled(Vector3.ONE * scale_by)
	_model.position = Vector3(0.0, -bounds.position.y * scale_by, 0.0)

	_paint(_model, atlas_path, colour)
	_scale_by = scale_by
	_arm = _model.find_child("arm-right", true, false) as Node3D
	_anim = _model.find_child("AnimationPlayer", true, false) as AnimationPlayer

	# [b]Advanced by [method pose], not by the engine[/b], so that the arm can be held up
	# AFTER the walk has been applied to it. The kit's `holding-right` clip is the whole body
	# standing still with one arm out; playing it would stop the legs. Left to the engine, the
	# player's own process and this one's run in an order nothing here controls, and an arm
	# set before the clip writes it is an arm the clip puts back down.
	if _anim != null:
		_anim.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL


## Puts the figure where this frame draws its player, facing [param yaw_radians], moving at
## [param speed] metres a second over the ground.
func pose(at: Vector3, yaw_radians: float, speed: float) -> void:
	global_position = at
	rotation = Vector3(0.0, yaw_radians, 0.0)

	var wanted := &"idle"

	if speed >= RUN_FROM:
		wanted = &"sprint"
	elif speed >= WALK_FROM:
		wanted = &"walk"

	_play(wanted)

	if _anim != null:
		var now := Time.get_ticks_usec()
		# A figure that was hidden for a minute is not a minute behind: clamped, so it picks
		# up the clip where it was rather than fast-forwarding through it in one frame.
		var delta := 0.0 if _posed_at_usec < 0 else clampf((now - _posed_at_usec) / 1e6, 0.0, 0.1)
		_posed_at_usec = now
		_anim.advance(delta)

	# The kit's own `holding-right` pose, over whatever the legs are doing: one rotation of
	# the arm about its shoulder, measured off the clip (-90 degrees about X).
	if _arm != null and holding != &"":
		_arm.rotation = HOLD_ARM


## Draws [param id] in the right hand, or nothing for an empty id. [param switching] hides
## it mid-switch, the way [ZeeWorldModel] does.
##
## [b]Asked every frame and cheap when nothing changed[/b]: the model is only re-equipped
## when the id differs from what is drawn.
func hold(id: StringName, switching: bool) -> void:
	holding = id

	if id == &"":
		if held != null:
			held.visible = false
		return

	if held == null:
		held = ZeeWorldModel.new()
		held.name = "Held"
		# This game has its own sound for somebody else's shot, by kind, played from the
		# counter (`WoAudio.on_weapon`); the hand draws the flash and the tracer. By name,
		# for a shell older than the property: see its own note.
		held.set(&"sounds", false)

		if not held.attach_to(self):
			held.free()
			held = null
			return

	if held.equipped() != id:
		var art: Variant = ZeeWeaponArtTable.table().get(id)

		if art is ZeeWeaponArt:
			var _drawn := held.equip(art as ZeeWeaponArt)
		else:
			held.clear()

	held.visible = true
	held.on_switching(switching)


## The weapon in this figure's hand was used [param times] times, as a [ZeeWeaponNet] kind.
## One kick however many, as `ZeeWeaponNet.apply` does: a burst's recoil in one frame reads
## as the gun jumping out of the hand.
func fired(times: int, kind: int) -> void:
	if times <= 0 or held == null or not held.visible:
		return

	held.on_fired(WATCHED_RECOIL.get(kind, Vector2(0.6, 0.1)), kind)


## The node a held weapon hangs from, by the name [ZeeWorldModel] asks for.
##
## [b]At the end of the kit's right arm, as a child of it[/b], so the gun moves with the arm
## — the shot's kick in the clip, a melee swing — rather than floating at a fixed point in
## front of the chest. Turned so that its -Z is the way the arm points when it is held up and
## its +Y is up, and scaled back to metres, because the model it hangs in is scaled to the
## player's hull and a weapon drawn at two-thirds of its size reads as a toy.
func attachment(point: StringName) -> Node3D:
	if point != &"right_hand":
		return null

	if _hand != null and is_instance_valid(_hand):
		return _hand

	_hand = Node3D.new()
	_hand.name = "RightHand"

	if _arm != null:
		var unscale := 1.0 / maxf(_scale_by, 0.01)
		_hand.transform = Transform3D(HAND_BASIS.scaled(Vector3.ONE * unscale), HAND_AT)
		_arm.add_child(_hand)
	elif _model != null:
		# The capsule: chest high, right of centre, in front.
		_hand.position = Vector3(0.26, 1.12, -0.34)
		_model.add_child(_hand)
	else:
		_hand.free()
		_hand = null

	return _hand


## The arm, held up: the `holding-right` clip's one rotation.
const HOLD_ARM := Vector3(-PI * 0.5, 0.0, 0.0)

## Where the hand is in the arm's own frame: the bottom of the arm's mesh, at the middle of
## its cross-section ((-0.4..0, -1..0.1, -0.2..0.2) in the kit's units).
const HAND_AT := Vector3(-0.2, -0.92, 0.0)

## The hand's axes in the arm's frame: +X across, +Y along the arm's +Z (up, once the arm is
## raised), +Z up the arm toward the shoulder — so -Z runs down it, out of the fist.
const HAND_BASIS := Basis(Vector3(-1.0, 0.0, 0.0), Vector3(0.0, 0.0, 1.0), Vector3(0.0, 1.0, 0.0))

## How far a watched gun kicks per kind of use, in the recoil's own degrees. The real
## recoil is on an outcome that does not travel, so a watcher's is approximate on purpose;
## game-arena's numbers.
const WATCHED_RECOIL := {
	ZeeWeaponNet.KIND_SWING: Vector2(1.2, 0.0),
	ZeeWeaponNet.KIND_SPAWN: Vector2(2.0, 0.0),
	ZeeWeaponNet.KIND_THROW: Vector2(2.0, 0.0),
	ZeeWeaponNet.KIND_BEAM: Vector2(0.05, 0.0),
}


func _play(wanted: StringName) -> void:
	if _anim == null or clip == wanted or not _anim.has_animation(wanted):
		return

	clip = wanted
	# The kit's clips are imported as one-shots. A walk that stops after one stride reads as
	# somebody sliding the rest of the way across the platform.
	var animation := _anim.get_animation(wanted)
	if animation != null:
		animation.loop_mode = Animation.LOOP_LINEAR
	_anim.play(wanted, 0.15)


static func _bounds(node: Node, to_root: Transform3D) -> AABB:
	var out := AABB()
	var seeded := false
	var mesh := node as MeshInstance3D

	if mesh != null and mesh.mesh != null:
		out = to_root * mesh.mesh.get_aabb()
		seeded = true

	for child in node.get_children():
		var child_to_root := to_root
		if child is Node3D:
			child_to_root = to_root * (child as Node3D).transform
		var inner := _bounds(child, child_to_root)
		# An empty AABB is a branch with no mesh in it; merging one would pull the bounds out
		# to the origin of whatever node it came from.
		if inner.size == Vector3.ZERO and inner.position == Vector3.ZERO:
			continue
		out = inner if not seeded else out.merge(inner)
		seeded = true

	return out


func _paint(root: Node, atlas_path: String, colour: Color) -> void:
	var texture: Variant = load(WoPaths.rebase(atlas_path))

	if not (texture is Texture2D):
		DotLog.warn(CHANNEL, "a character atlas is missing", {"path": atlas_path})
		return

	# Unshaded, as the kit's own material is (`KHR_materials_unlit`), and nearest-filtered
	# because the atlas is pixel art.
	var plain := StandardMaterial3D.new()
	plain.albedo_texture = texture
	plain.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	plain.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST

	var side := plain.duplicate() as StandardMaterial3D
	side.albedo_color = Color.WHITE.lerp(colour, TEAM_TINT)

	for node in _meshes(root):
		node.material_override = side if node.name == &"torso" else plain


static func _meshes(node: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	var as_mesh := node as MeshInstance3D

	if as_mesh != null:
		out.append(as_mesh)

	for child in node.get_children():
		out.append_array(_meshes(child))

	return out


static func _capsule(height: float, colour: Color) -> Node3D:
	var root := Node3D.new()
	root.name = "Capsule"

	var material := StandardMaterial3D.new()
	material.albedo_color = colour

	var trunk := MeshInstance3D.new()
	var capsule := CapsuleMesh.new()
	capsule.radius = 0.35
	capsule.height = height
	trunk.mesh = capsule
	trunk.material_override = material
	trunk.position = Vector3(0.0, height * 0.5, 0.0)
	root.add_child(trunk)

	# A nose, so which way they face reads from across the field.
	var nose := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.16, 0.16, 0.3)
	nose.mesh = box
	nose.material_override = material
	nose.position = Vector3(0.0, height * 0.85, -0.4)
	root.add_child(nose)

	return root


func describe() -> Dictionary:
	return {
		"art": from_art,
		"atlas": atlas.get_file(),
		"visible": visible,
		"clip": String(clip),
		"holding": String(holding),
		"at": str(global_position.snapped(Vector3.ONE * 0.01)) if is_inside_tree() else "-",
	}
