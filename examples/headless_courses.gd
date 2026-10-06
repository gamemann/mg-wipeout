extends Node

const WoCatalogue := preload("../game/wo_catalogue.gd")
const WoConfig := preload("../game/wo_config.gd")
const WoCourse := preload("../game/wo_course.gd")
const WoGame := preload("../game/wo_game.gd")
const WoPlayer := preload("../game/wo_player.gd")

## Every installed course is run to the finish by a stand-in, and every arena is stood in.
##
## [b]A course is content, and content is checked by playing it.[/b] A document that validates
## can still have a gap nobody clears, an arm with no window, a mover that never reaches the far
## side or a finish nobody can get to — and none of those is an error anywhere. So each course
## here is run by a bot that never fumbles, on the route the document gives, with every hazard
## live and the bot waiting for its windows the way [WoGame] lets it; a course it cannot finish
## inside its own clock is a course to fix, and this says which one and where the bot got to.
##
## [b]Ticks are not paced by the engine's frames[/b], because ten courses at real time is half
## an hour. The simulation does not notice: every tick is a fixed step the suite drives itself.
##
## Without the mg-wipeout-maps link (a fresh clone) this runs the built-in practice course and
## arena only, and says so.

const TICK_RATE := 64
const TICK := 1.0 / float(TICK_RATE)

var _passed := 0
var _failed := 0
var _sections_entered := 0
var _sections_finished := 0
var _failures := PackedStringArray()
var _world: WoGame = null


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("wipeout: every course run, every arena stood in")
	print("")

	var catalogue := WoCatalogue.new()
	var _loaded := catalogue.load_from("courses")
	var courses := catalogue.courses.keys()
	courses.sort()
	var arenas := catalogue.arenas.keys()
	arenas.sort()

	if courses.size() <= 1:
		print("(no course directory: the built-in practice course and arena only)")

	_section("every document loads")
	_check(catalogue.refused.is_empty(), "none was refused", str(catalogue.refused))
	_finished()

	for id: StringName in courses:
		await _run_course(catalogue.courses[id])

	for id: StringName in arenas:
		await _stand_in_arena(catalogue.arenas[id])

	if _world != null:
		remove_child(_world)
		_world.free()

	var sections := 1 + courses.size() + arenas.size()
	var checks := 1 + courses.size() * 3 + arenas.size() * 4

	print("")
	print("%d sections entered, %d finished" % [_sections_entered, _sections_finished])
	print("%d passed, %d failed" % [_passed, _failed])

	for line in _failures:
		print("  FAIL  %s" % line)

	var code := 1 if _failed > 0 else 0

	if _sections_entered != _sections_finished or _sections_entered != sections:
		print("ERROR: %d of %d sections finished, %d expected." % [_sections_finished, _sections_entered, sections])
		code = 1

	if _passed + _failed != checks:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [_passed + _failed, checks])
		code = 1

	get_tree().quit(code)


func _run_course(doc: Dictionary) -> void:
	_section("%s — %s" % [doc["id"], doc["name"]])
	var game := await _fresh_world(doc)
	var bot := game.add_player(&"u900001", "Runner")
	bot.is_bot = true
	var idle := game.add_player(&"u2", "Watcher")
	game.start()

	var limit := game.course_limit() + game.config.countdown_seconds + 1.0
	var ticks := int(limit * TICK_RATE)
	var furthest := -1
	var deepest := 0.0
	var started := false

	for i in range(ticks):
		idle.controller.apply_command(DotFpsCommand.new())
		game.simulate(TICK)

		# Not a physics frame per tick: every moving piece writes its transform straight into
		# the physics server (see `WoCourse._place`), so a query on the next tick already sees
		# it, and waiting on the engine's own frame pacing made ten courses take an hour.
		if i % 512 == 0:
			await get_tree().process_frame

		if game.phase == WoGame.Phase.COURSE:
			started = true
		elif started:
			break

		furthest = maxi(furthest, bot.checkpoint)
		deepest = minf(deepest, bot.controller.state.position.z)

		if bot.finished:
			break

	var where := bot.controller.state.position
	_check(bot.finished, "a stand-in finished it", "%s in %.1f s, %d falls, %d knocks" % [
		"finished" if bot.finished else "got to z %.1f, last at %s, checkpoint %d" % [deepest, where, furthest],
		bot.finish_seconds if bot.finished else game.course_elapsed, bot.falls, bot.knocks])
	_check(furthest == game.stage.checkpoint_count() - 1 or not bot.finished,
		"crossing every checkpoint on the way", "%d of %d" % [furthest + 1, game.stage.checkpoint_count()])
	_check(game.stage.pieces.size() >= 8 or str(doc["id"]) == "wo_practice",
		"with something in it", "%d pieces, %d hazards" % [game.stage.pieces.size(), game.stage.describe()["hazards"]])
	_finished()


func _stand_in_arena(doc: Dictionary) -> void:
	_section("%s — %s" % [doc["id"], doc["name"]])
	var game := await _fresh_world(doc)
	await get_tree().physics_frame
	game.stage.pose_at(0)
	var space := game.get_world_3d().direct_space_state
	var floorless := PackedStringArray()

	for area: Dictionary in doc["spawns"]:
		if not _floor_under(space, area["at"]):
			floorless.append(str(area["at"]))

	_check(floorless.is_empty(), "every spawn area has floor under it", ", ".join(floorless))

	floorless.clear()

	for area: Dictionary in doc["drops"]:
		if not _floor_under(space, area["at"]):
			floorless.append(str(area["at"]))

	_check(floorless.is_empty(), "every drop area has floor under it", ", ".join(floorless))

	var gallery: Vector3 = doc["gallery"]["at"]
	_check(_floor_under(space, gallery), "the gallery has a floor")

	# Out of the gallery is a wall in every direction, so a watcher cannot join the fight.
	var open := PackedStringArray()

	for direction in [Vector3.LEFT, Vector3.RIGHT, Vector3.FORWARD, Vector3.BACK]:
		var from := gallery + Vector3(0, 1.5, 0)
		var query := PhysicsRayQueryParameters3D.create(from, from + direction * 30.0)
		if space.intersect_ray(query).is_empty():
			open.append(str(direction))

	_check(open.is_empty(), "and walls all round it", ", ".join(open))
	_finished()


func _floor_under(space: PhysicsDirectSpaceState3D, at: Vector3) -> bool:
	var query := PhysicsRayQueryParameters3D.create(at + Vector3(0, 3.0, 0), at + Vector3(0, -3.0, 0))
	return not space.intersect_ray(query).is_empty()


func _fresh_world(doc: Dictionary) -> WoGame:
	if _world != null:
		remove_child(_world)
		_world.free()
		await get_tree().process_frame

	var config := WoConfig.new()
	# What this suite proves is that a course can be FINISHED; a stand-in knocked nine times
	# before its first checkpoint would be knocked out of the round, which is a fact about the
	# stand-in. Damage and weather are headless_run's.
	config.knock_damage_per_speed = 0.0
	config.wind_chance = 0.0
	config.storm_chance = 0.0
	config.warmup_seconds = 0.0
	config.intermission_seconds = 0.0
	config.countdown_seconds = 0.5
	config.minimum_players = 0
	config.bot_fumble_chance = 0.0
	config.keep_progress = false
	config.course_ids = PackedStringArray([str(doc["id"])]) if str(doc["kind"]) == "course" \
		else PackedStringArray(["wo_practice"])

	var game := WoGame.new()
	game.name = "World"
	game.config = config
	game.tick_rate = TICK_RATE
	game.register_service = false
	add_child(game)
	game.set_physics_process(false)
	_world = game

	if str(doc["kind"]) == "arena":
		var _built := game.build_stage(doc)

	await get_tree().physics_frame
	await get_tree().physics_frame
	return game


func _section(name: String) -> void:
	_sections_entered += 1
	print(name)


func _finished() -> void:
	_sections_finished += 1


func _check(ok: bool, what: String, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("  ok    %s%s" % [what, "" if detail == "" else "  (%s)" % detail])
		return

	_failed += 1
	var line := "%s%s" % [what, "" if detail == "" else "  (%s)" % detail]
	_failures.append(line)
	print("  FAIL  %s" % line)
