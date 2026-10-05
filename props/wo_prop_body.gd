extends RigidBody3D

const WoPaths := preload("../game/wo_paths.gd")

## One thing the cannon throws: a rigid body that builds its own mesh and its own collider
## from four exported numbers.
##
## [b]Eight props, one script, and the model is loaded by PATH rather than instanced as an
## `ext_resource`.[/b] That is a delivery decision. A `.tscn` records an external resource
## as an absolute `res://` path plus a UID, and inside a mounted dot-cloud pack neither
## resolves: game-buses-from-hell shipped a round where every crate's mesh loaded and every
## crate's texture did not, which is a game that plays perfectly and appears to have
## shipped without art. Loading through [method WoPaths.rebase] is one form that is right
## both built in and delivered, and it lets the atlas be put on by hand — see
## [method _paint].
##
## [b]The collider is a primitive and is not taken off the model.[/b] The art is a box, a
## barrel and three rocks; the physics is a box, a cylinder and a sphere. A convex hull
## would be more faithful and much worse: dot-props already documents what loose triangles
## do to a sliding body, and everything here spends its life sliding across a tilting
## platform.

const CHANNEL := "wo.prop"

## The two atlases, rebased where they are defined. They are rebased again at load, which
## is a no-op on these and is what makes an [code]atlas_path[/code] set in a scene safe
## too — the publisher has already rewritten that one onto the mount.
##
## [b]Two files with the same name, and they are different files.[/b] Flattening the kits
## into one folder paints the survival props in the car kit's palette, which is a
## plausible-looking wrong answer that no assertion would ever catch.
static var SURVIVAL_ATLAS := WoPaths.rebase("res://assets/kenney/survival/Textures/colormap.png")
static var CAR_ATLAS := WoPaths.rebase("res://assets/kenney/car/Textures/colormap.png")

## What shape stands in for the model.
enum Shape {
	BOX,
	CYLINDER,
	SPHERE,
}

@export_group("Art")

## The model, as this game was authored. Rebased at load.
@export var model_path: String = ""

## What the model is multiplied by to reach the size below.
##
## [b]Measured per model rather than guessed, and every one of them needed a different
## number.[/b] Kenney's survival box is 0.25 m across and the car kit's tyre is 0.6 m, so
## one scale for the kit would make half the catalogue the wrong size. The figures are in
## this repository's CLAUDE.md so nobody has to measure them twice.
@export var model_scale: float = 1.0

## Metres the model is moved down by, so a model whose origin is at its foot is centred on
## the collider rather than hanging out of the top of it.
@export var model_drop: float = 0.0

## Which kit's atlas this model wants.
@export var atlas_path: String = SURVIVAL_ATLAS

@export_group("Physics")

@export var shape_kind: Shape = Shape.BOX

## The box's full size, or (radius, height, unused) for a cylinder, or (radius, ...) for a
## sphere.
@export var shape_size: Vector3 = Vector3.ONE

## Degrees the collider alone is turned by, for a model whose axis is not Godot's.
##
## A tyre lies on its side: the mesh's axle runs along X and a [CylinderShape3D]'s runs
## along Y, so the shape is turned and the mesh is not.
@export var shape_rotation: Vector3 = Vector3.ZERO


func _ready() -> void:
	# Mass is NOT set here. [method DotPropSpawner.spawn] writes the catalogue's figure
	# onto the body before it enters the tree, which is the addon being right: a scene
	# saved at one mass and a definition claiming another is two numbers that are only
	# ever compared by a player wondering why something bounced.
	_build_collider()
	_build_model()


func _build_collider() -> void:
	var collider := CollisionShape3D.new()
	collider.name = "Collision"
	collider.rotation = Vector3(
		deg_to_rad(shape_rotation.x),
		deg_to_rad(shape_rotation.y),
		deg_to_rad(shape_rotation.z)
	)

	match shape_kind:
		Shape.CYLINDER:
			var cylinder := CylinderShape3D.new()
			cylinder.radius = maxf(shape_size.x, 0.01)
			cylinder.height = maxf(shape_size.y, 0.02)
			collider.shape = cylinder
		Shape.SPHERE:
			var sphere := SphereShape3D.new()
			sphere.radius = maxf(shape_size.x, 0.01)
			collider.shape = sphere
		_:
			var box := BoxShape3D.new()
			box.size = Vector3(
				maxf(shape_size.x, 0.01),
				maxf(shape_size.y, 0.01),
				maxf(shape_size.z, 0.01)
			)
			collider.shape = box

	add_child(collider)


func _build_model() -> void:
	if model_path == "":
		return

	var path := WoPaths.rebase(model_path)
	var scene: PackedScene = load(path) as PackedScene

	if scene == null:
		# Not fatal and not silent. A prop with no mesh still falls, still hits a platform
		# and still kills somebody — what it does not do is warn them it was coming, which
		# is a game that reads as broken rather than as missing one file.
		DotLog.warn(CHANNEL, "a prop model would not load", {"path": path, "prop": name})
		return

	var art := scene.instantiate() as Node3D

	if art == null:
		return

	art.name = "Art"
	art.scale = Vector3.ONE * model_scale
	art.position = Vector3(0.0, -model_drop * model_scale, 0.0)
	add_child(art)

	_paint(art)


## Gives every untextured material under [param root] this prop's atlas.
##
## [b]An imported GLB names its texture by UID and by the absolute path it had when it was
## imported, and a delivered pack has neither.[/b] The loader falls back to the path, the
## path is `res://assets/…` which in the host project is another game's directory or
## nothing, and the mesh loads white. game-buses-from-hell found this by looking at a
## screenshot of a real client; dot-cloud now registers a mounted pack's own UIDs and this
## is the belt to that braces.
##
## [b]Surgical, not an override.[/b] It touches only a material that has no albedo texture,
## so in a build — where the import worked — it does exactly nothing and the picture a
## developer sees is the picture a player gets. An unconditional `material_override` would
## be a second definition of how these models look, free to drift from the one in the file.
func _paint(root: Node) -> void:
	var meshes := _meshes(root)

	if meshes.is_empty():
		return

	var atlas: Texture2D = null
	var repaired := 0

	for mesh in meshes:
		for surface in range(maxi(mesh.get_surface_override_material_count(), 1)):
			var material := mesh.get_active_material(surface) as BaseMaterial3D

			if material == null or material.albedo_texture != null:
				continue

			if atlas == null:
				# Loaded lazily: a build never reaches here, and loading a texture in order
				# to decide it was not needed is the sort of cost that shows up on a phone.
				atlas = load(WoPaths.rebase(atlas_path)) as Texture2D

				if atlas == null:
					DotLog.warn(CHANNEL, "the atlas is missing from this build", {
						"path": WoPaths.rebase(atlas_path),
					})
					return

			# On a DUPLICATE, and this is the line that stops one repair painting the whole
			# game: an imported scene's materials are shared between every instance of it,
			# so writing into one writes into all of them — and the two kits' atlases are
			# different files, so a later car-kit prop would repaint every survival one.
			var fixed: BaseMaterial3D = material.duplicate()
			fixed.albedo_texture = atlas
			mesh.set_surface_override_material(surface, fixed)
			repaired += 1

	if repaired > 0:
		DotLog.debug(CHANNEL, "the art was repainted from the mount", {
			"materials": repaired, "prop": name,
		})


static func _meshes(node: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	var as_mesh := node as MeshInstance3D

	if as_mesh != null:
		out.append(as_mesh)

	for child in node.get_children():
		out.append_array(_meshes(child))

	return out
