extends Node

## Runs one course with one stand-in and prints every fall and every knock: where, and which
## route point it was heading for. The tool for "a stand-in cannot finish this course" — the
## suite says that it happened, this says where.
##
##   godot --headless --path . res://tools/trace_course.tscn -- --course=wo_big_balls [--seconds=120] [--every=0.5]

const WoConfig := preload("../game/wo_config.gd")
const WoGame := preload("../game/wo_game.gd")


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	var course := "wo_practice"
	var seconds := 120.0
	var every := 0.0

	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--course="):
			course = arg.trim_prefix("--course=")
		elif arg.begins_with("--every="):
			every = arg.trim_prefix("--every=").to_float()
		elif arg.begins_with("--seconds="):
			seconds = arg.trim_prefix("--seconds=").to_float()

	var config := WoConfig.new()
	config.warmup_seconds = 0.0
	config.countdown_seconds = 0.5
	config.minimum_players = 0
	config.bot_fumble_chance = 0.0
	config.keep_progress = false
	config.course_seconds = seconds
	config.course_ids = PackedStringArray([course])

	var game := WoGame.new()
	game.config = config
	game.register_service = false
	add_child(game)
	game.set_physics_process(false)
	await get_tree().physics_frame
	await get_tree().physics_frame

	var bot := game.add_player(&"u900001", "Runner")
	bot.is_bot = true
	var idle := game.add_player(&"u2", "Watcher")
	# A dictionary, because a GDScript lambda captures locals BY VALUE: a counter it bumps is
	# its own copy, and a position it prints is the one from when it was made.
	var seen := {"ground": Vector3.ZERO, "route": 0, "lines": 0, "knocks": 0}
	game.player_fell.connect(func(id: StringName, cp: int) -> void:
		if id == bot.player_id and int(seen["lines"]) < 40:
			seen["lines"] = int(seen["lines"]) + 1
			print("fell  from %s  heading for route %d  checkpoint %d  t=%.1f" % [
				seen["ground"], seen["route"], cp, game.course_elapsed])
	)
	game.start()

	for i in range(int((seconds + 2.0) * 64)):
		idle.controller.apply_command(DotFpsCommand.new())
		game.simulate(1.0 / 64.0)

		if bot.controller.state.mode == DotFpsState.Mode.GROUND:
			seen["ground"] = bot.controller.state.position.snapped(Vector3(0.01, 0.01, 0.01))

		seen["route"] = int(game._bot_route.get(bot.player_id, 0))

		if every > 0.0 and i % maxi(int(every * 64.0), 1) == 0:
			print("t=%.2f %s at %s v %s route %d wait %d" % [game.course_elapsed,
				WoGame.Phase.keys()[game.phase], bot.controller.state.position.snapped(Vector3(0.01, 0.01, 0.01)),
				bot.controller.state.velocity.snapped(Vector3(0.1, 0.1, 0.1)), seen["route"],
				int(game._bot_wait.get(bot.player_id, 0))])

		if bot.knocks != int(seen["knocks"]):
			seen["knocks"] = bot.knocks
			if int(seen["lines"]) < 40:
				seen["lines"] = int(seen["lines"]) + 1
				print("knock at %s  heading for route %d  t=%.1f" % [
					bot.controller.state.position.snapped(Vector3(0.01, 0.01, 0.01)),
					int(game._bot_route.get(bot.player_id, -1)), game.course_elapsed])

		if i == 200 and OS.get_environment("WO_PROBE") != "":
			var space := game.get_world_3d().direct_space_state
			for h in [0.1, 0.5, 1.0]:
				var q := PhysicsRayQueryParameters3D.create(Vector3(1, h, -7), Vector3(1, h, 0))
				var hit := space.intersect_ray(q)
				print("probe h=%.1f -> %s %s" % [h, hit.get("position"), (hit.get("collider") as Node).get_path() if hit.has("collider") else ""])

		if bot.finished:
			print("FINISHED in %.1f s, %d falls, %d knocks" % [bot.finish_seconds, bot.falls, bot.knocks])
			break

	if not bot.finished:
		print("did not finish: %d falls, %d knocks, at %s" % [bot.falls, bot.knocks, bot.controller.state.position])

	get_tree().quit()
