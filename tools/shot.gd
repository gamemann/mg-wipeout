extends Node

## Renders the game and saves a frame. The check no assertion in this repository makes.
##
##   tools/shot.sh                                  # a player's own eyes, a few seconds in
##   tools/shot.sh --view=course --wo-course-ids=wo_spin_cycle
##   tools/shot.sh --view=start                     # the start pad, from behind the runners
##   tools/shot.sh --view=hazard                    # the first thing that throws you, close
##   tools/shot.sh --view=tiles --wo-course-ids=wo_trapdoor_run   # drop-tiles, warning in red
##   tools/shot.sh --view=third                     # third person, mid-course
##   tools/shot.sh --view=arena --arena=wo_arena_pit   # an arena, from above
##   tools/shot.sh --view=finale                    # a real final death, from a finisher's eyes
##
## Any `--wo-*` is the game's own configuration (see `WoConfig`), because `WoClient` reads it.

const WoClient := preload("../game/wo_client.gd")
const WoGame := preload("../game/wo_game.gd")

var _view := "eyes"
var _seconds := 4.0
var _out := "res://screenshots/shot.png"
var _arena := ""
var _client: Node = null


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--view="):
			_view = arg.trim_prefix("--view=")
		elif arg.begins_with("--seconds="):
			_seconds = arg.trim_prefix("--seconds=").to_float()
		elif arg.begins_with("--out="):
			_out = arg.trim_prefix("--out=")
		elif arg.begins_with("--arena="):
			_arena = arg.trim_prefix("--arena=")

	_client = WoClient.new()
	_client.name = "Client"
	_client.set("force_offline", true)
	_client.set("third_person", _view == "third")
	add_child(_client)
	_run.call_deferred()


func _run() -> void:
	var game: WoGame = _client.get("game")
	game.config.warmup_seconds = 0.0
	game.config.countdown_seconds = 1.0

	match _view:
		"arena":
			await _frames(4)
			var doc: Dictionary = game.catalogue.arenas.get(StringName(_arena), {}) if _arena != "" \
				else game.catalogue.pick_arena(game.config.arena_ids, DotRandomStream.new(3))
			if doc.is_empty():
				doc = game.catalogue.pick_arena(PackedStringArray(), DotRandomStream.new(3))
			var _built := game.build_stage(doc)
			await _frames(6)
			_overview(game, 0.9)
		"finale":
			await _seconds_of(game.config.countdown_seconds + 1.5)
			# Everybody across, so the course closes into a final death the way a real one does.
			for id: StringName in game.players:
				var runner = game.players[id]
				if runner.finished:
					continue
				game._finish_count += 1
				runner.finished = true
				runner.place = game._finish_count
			await _seconds_of(game.config.handover_seconds + 1.5)
		"course":
			await _frames(6)
			_overview(game, 1.0)
		"start":
			await _seconds_of(0.6)
			var camera := _free_camera()
			var start: Vector3 = game.course_doc["start"]["at"]
			camera.look_at_from_position(start + Vector3(0, 5.5, 10.0), start + Vector3(0, 0, -14.0))
		"tiles":
			await _seconds_of(_seconds)
			var camera := _free_camera()
			for piece in game.stage.pieces:
				if str(piece["kind"]) == "tiles":
					var at: Vector3 = piece["spec"]["at"]
					camera.look_at_from_position(at + Vector3(6.0, 6.0, 7.0), at)
					break
		"hazard":
			await _seconds_of(_seconds)
			var hazard := _first_hazard(game)
			var camera := _free_camera()
			camera.look_at_from_position(hazard + Vector3(7.0, 5.0, 7.0), hazard + Vector3(0, 0.6, 0))
		_:
			await _seconds_of(_seconds)

	await _frames(3)
	var image := get_viewport().get_texture().get_image()
	var path := ProjectSettings.globalize_path(_out)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var saved := image.save_png(path)
	print("saved %s (%s): %s" % [_out, _view, error_string(saved)])
	get_tree().quit(0 if saved == OK else 1)


func _overview(game: WoGame, reach_scale: float) -> void:
	var box: AABB = game.stage.bounds()
	var centre := box.get_center()
	var reach := maxf(box.size.length() * 0.5, 14.0) * reach_scale
	var camera := _free_camera()
	camera.look_at_from_position(centre + Vector3(reach * 0.75, reach * 0.6 + 6.0, reach * 0.35), centre)


func _first_hazard(game: WoGame) -> Vector3:
	for piece in game.stage.pieces:
		if bool(piece["hazard"]):
			var spec: Dictionary = piece["spec"]
			return spec.get("at", spec.get("pivot", Vector3.ZERO))
	return Vector3.ZERO


func _free_camera() -> Camera3D:
	var camera := Camera3D.new()
	camera.fov = 70.0
	add_child(camera)
	camera.current = true
	return camera


func _frames(count: int) -> void:
	for _i in range(count):
		await get_tree().process_frame


func _seconds_of(seconds: float) -> void:
	var until := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < until:
		await get_tree().process_frame
