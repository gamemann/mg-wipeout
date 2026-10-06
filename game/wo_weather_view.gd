extends Node3D

## What the weather looks like: rain round the camera on a stormy course, and each
## lightning strike drawn on the tick it lands. Client side, drawing only; what the weather
## DOES is [WoCourse.wind] and [WoCourse.strike], which every machine computes from the tick.

const WoCourse := preload("wo_course.gd")

var stage: WoCourse = null
var camera: Camera3D = null

## The game's tick, as a Callable, so this reads the same clock the simulation does.
var tick_fn: Callable = Callable()

var _rain: CPUParticles3D = null
var _last_tick: int = -1
var _bolts: Array[Dictionary] = []

## The sky's brightness before a storm dimmed it, so it can be put back. -1: not dimmed.
var _clear_sky: float = -1.0
var _clear_light: float = -1.0


func _ready() -> void:
	_rain = CPUParticles3D.new()
	_rain.name = "Rain"
	_rain.amount = 900
	_rain.lifetime = 0.9
	_rain.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	_rain.emission_box_extents = Vector3(14.0, 0.5, 14.0)
	_rain.direction = Vector3(0.0, -1.0, 0.0)
	_rain.spread = 4.0
	_rain.initial_velocity_min = 22.0
	_rain.initial_velocity_max = 28.0
	_rain.gravity = Vector3.ZERO
	var drop := BoxMesh.new()
	drop.size = Vector3(0.015, 0.35, 0.015)
	var wet := StandardMaterial3D.new()
	wet.albedo_color = Color(0.75, 0.82, 0.95, 0.5)
	wet.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	wet.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	drop.material = wet
	_rain.mesh = drop
	_rain.emitting = false
	add_child(_rain)


func _process(delta: float) -> void:
	if stage == null or not is_instance_valid(stage):
		return

	var stormy := stage.is_stormy()
	_rain.emitting = stormy
	_dim(stormy)
	if stormy and camera != null:
		_rain.global_position = camera.global_position + Vector3(0.0, 9.0, 0.0)

	var now := int(tick_fn.call()) if tick_fn.is_valid() else -1
	if now > _last_tick and _last_tick >= 0 and now - _last_tick < 64:
		for tick in range(_last_tick + 1, now + 1):
			var bolt := stage.strike_at(tick)
			if not bolt.is_empty():
				_draw_bolt(bolt["at"])
	_last_tick = now

	for index in range(_bolts.size() - 1, -1, -1):
		var bolt: Dictionary = _bolts[index]
		bolt["age"] = float(bolt["age"]) + delta
		var fade := 1.0 - clampf(float(bolt["age"]) / 0.35, 0.0, 1.0)
		(bolt["light"] as OmniLight3D).light_energy = 16.0 * fade
		(bolt["mesh"] as MeshInstance3D).visible = fade > 0.4
		if fade <= 0.0:
			(bolt["light"] as Node).queue_free()
			(bolt["mesh"] as Node).queue_free()
			_bolts.remove_at(index)


## A storm is dark: the sky and the sun down to under half, put back when it passes. The
## first render had rain falling out of a bright clear sky, which reads as a bug.
func _dim(stormy: bool) -> void:
	var world := get_viewport().world_3d if is_inside_tree() else null
	var env := world.environment if world != null else null
	var sun := _sun()
	if stormy and _clear_sky < 0.0:
		if env != null:
			_clear_sky = env.background_energy_multiplier
			env.background_energy_multiplier = _clear_sky * 0.4
		if sun != null:
			_clear_light = sun.light_energy
			sun.light_energy = _clear_light * 0.45
	elif not stormy and _clear_sky >= 0.0:
		if env != null:
			env.background_energy_multiplier = _clear_sky
		if sun != null and _clear_light >= 0.0:
			sun.light_energy = _clear_light
		_clear_sky = -1.0
		_clear_light = -1.0


func _sun() -> DirectionalLight3D:
	var found := get_tree().root.find_children("*", "DirectionalLight3D", true, false)
	return found[0] as DirectionalLight3D if not found.is_empty() else null


## A bolt: a white column from the sky to the spot, and a flash of light round it.
func _draw_bolt(at: Vector3) -> void:
	var column := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.08
	mesh.bottom_radius = 0.2
	mesh.height = 40.0
	var glow := StandardMaterial3D.new()
	glow.albedo_color = Color(0.9, 0.93, 1.0)
	glow.emission_enabled = true
	glow.emission = Color(0.85, 0.9, 1.0)
	glow.emission_energy_multiplier = 6.0
	glow.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mesh.material = glow
	column.mesh = mesh
	add_child(column)
	column.global_position = at + Vector3(0.0, 20.0, 0.0)

	var light := OmniLight3D.new()
	light.omni_range = 30.0
	light.light_energy = 16.0
	light.light_color = Color(0.85, 0.9, 1.0)
	add_child(light)
	light.global_position = at + Vector3(0.0, 3.0, 0.0)

	_bolts.append({"mesh": column, "light": light, "age": 0.0})


func bolt_count() -> int:
	return _bolts.size()
