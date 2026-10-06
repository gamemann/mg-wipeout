extends Node

const WoCatalogue := preload("../game/wo_catalogue.gd")
const WoConfig := preload("../game/wo_config.gd")
const WoContent := preload("../game/wo_content.gd")
const WoCourse := preload("../game/wo_course.gd")
const WoCourseDoc := preload("../game/wo_course_doc.gd")
const WoGame := preload("../game/wo_game.gd")
const WoPaths := preload("../game/wo_paths.gd")
const WoPlayer := preload("../game/wo_player.gd")
const WoProgress := preload("../game/wo_progress.gd")

## The simulation, headless: documents, the course, what it does to a player, and the round.
##
## [b]Counts sections AND checks, and the second is the one that matters.[/b] A script error
## inside a section aborts that function and the section counter is already satisfied,
## because the section announced itself on the way in. mg-smash-copter and dot-settings both
## have the story; every total here was armed by raising it by one and watching the run fail.

const SECTIONS := 19

const CHECKS := 93

const TICK_RATE := 64
const TICK := 1.0 / float(TICK_RATE)

var _passed := 0
var _failed := 0
var _sections_entered := 0
var _sections_finished := 0
var _failures := PackedStringArray()

var _worlds: Array[WoGame] = []


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("wipeout headless run")
	print("")

	_test_config()
	_test_documents()
	_test_the_wire()
	_test_catalogue()
	_test_delivery()
	_test_formulas()
	await _test_world_builds()
	await _test_the_gate()
	await _test_the_carry()
	await _test_the_turntable()
	await _test_the_knock()
	await _test_ducking()
	await _test_a_fall()
	await _test_a_bot_runs_the_course()
	await _test_one_finisher_wins()
	await _test_the_final_death()
	await _test_nobody_finishes()
	await _test_knocks_hurt()
	await _test_the_weather()

	for world in _worlds.duplicate():
		await _dispose(world)

	await get_tree().process_frame

	print("")
	print("%d sections entered, %d finished" % [_sections_entered, _sections_finished])
	print("%d passed, %d failed" % [_passed, _failed])

	for line in _failures:
		print("  FAIL  %s" % line)

	var code := 1 if _failed > 0 else 0

	if _sections_entered != _sections_finished or _sections_entered != SECTIONS:
		print("ERROR: %d of %d sections finished, %d expected." % [
			_sections_finished, _sections_entered, SECTIONS
		])
		code = 1

	if _passed + _failed != CHECKS:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [
			_passed + _failed, CHECKS
		])
		code = 1

	get_tree().quit(code)


# --- Without a world ------------------------------------------------------------

func _test_config() -> void:
	_section("the configuration")
	var config := WoConfig.new()
	_check(config.validate().ok, "the defaults validate")
	_check(not config.teams(), "solo by default", "team_count %d" % config.team_count)

	config.team_count = 1
	_check(not config.validate().ok, "one team is refused")

	config.team_count = 3
	_check(config.validate().ok and config.teams(), "three teams is teams")

	config.knock_max_speed = 2.0
	_check(not config.validate().ok, "a knock ceiling under its floor is refused")
	_finished()


func _test_documents() -> void:
	_section("a course is a document, and a bad one is refused with a reason")
	var practice := WoCatalogue.practice()
	_check(str(practice.get("id", "")) == "wo_practice", "the practice course validates")
	_check(practice["start"]["at"] is Vector3, "positions are normalised to vectors")
	_check((practice["pieces"][0] as Dictionary).has("yaw"), "an omitted yaw is filled in")

	var arena := WoCatalogue.practice_arena()
	_check(str(arena.get("kind", "")) == "arena" and (arena["spawns"] as Array).size() >= 2,
		"the practice arena validates, with spawn areas")

	var unknown := practice.duplicate(true)
	(unknown["pieces"] as Array).append({"kind": "trampoline", "at": [0, 0, 0]})
	var refused := WoCourseDoc.validate(unknown)
	_check(not refused.ok and str(refused.error).contains("trampoline"),
		"an unknown piece kind is refused, naming it", str(refused.error) if not refused.ok else "")

	var missing := practice.duplicate(true)
	(missing["pieces"] as Array).append({"kind": "spinner", "at": [0, 0, 0]})
	refused = WoCourseDoc.validate(missing)
	_check(not refused.ok and str(refused.error).contains("arm_length"),
		"a piece without a field it needs is refused, naming the field")

	var later := practice.duplicate(true)
	later["format"] = 2
	_check(not WoCourseDoc.validate(later).ok, "a document from a later format is refused")

	var no_finish := practice.duplicate(true)
	no_finish.erase("finish")
	_check(not WoCourseDoc.validate(no_finish).ok, "a course with no finish is refused")

	var one_corner := arena.duplicate(true)
	one_corner["spawns"] = [{"at": [0, 0, 0]}]
	_check(not WoCourseDoc.validate(one_corner).ok, "an arena with one spawn area is refused")

	var zero_period := practice.duplicate(true)
	(zero_period["pieces"] as Array).append({"kind": "pendulum", "pivot": [0, 5, 0], "length": 4,
		"radius": 1, "swing": 40, "period": 0})
	_check(not WoCourseDoc.validate(zero_period).ok, "a period of zero is refused")
	_finished()


func _test_the_wire() -> void:
	_section("the document travels, and arrives as the same document")
	var practice := WoCatalogue.practice()
	var bytes := WoCourseDoc.encode(practice)
	var back := WoCourseDoc.decode(bytes)
	_check(back.ok, "it decodes", back.error.message if not back.ok else "")
	_check(back.ok and WoCourseDoc.digest(back.value) == WoCourseDoc.digest(practice),
		"its digest is the one the server sent",
		"%d bytes" % bytes.size())
	_check(bytes.size() < WoCourseDoc.WIRE_LIMIT, "it is under the wire limit")

	var torn := bytes.slice(0, bytes.size() / 2)
	_check(not WoCourseDoc.decode(torn).ok, "half of it is refused, not built")
	_finished()


func _test_catalogue() -> void:
	_section("the catalogue")
	var catalogue := WoCatalogue.new()
	var _loaded := catalogue.load_from("courses")
	_check(catalogue.courses.has(&"wo_practice"), "the built-in course is always there")
	_check(catalogue.arenas.has(&"wo_practice_arena"), "the built-in arena is always there")
	_check(catalogue.refused.is_empty(), "no installed document was refused",
		", ".join(catalogue.refused.keys()))

	var ids := catalogue.playable_courses(PackedStringArray())
	_check(ids.size() == 1 or not ids.has(&"wo_practice"),
		"practice drops out once there is a real course", "%d playable" % ids.size())

	var stream := DotRandomStream.new(7)
	var first := catalogue.next_course(PackedStringArray(), true, stream, &"")
	var second := catalogue.next_course(PackedStringArray(), true, stream, StringName(str(first["id"])))
	_check(ids.size() < 2 or str(first["id"]) != str(second["id"]),
		"a shuffle does not repeat the course just played")
	_finished()


## Every bare `"res://…"` string in a shipped script that names one of this game's own
## directories, and every `class_name`. A delivered pack cannot use either; see
## mg-smash-copter's Decision 7.
func _test_delivery() -> void:
	_section("what a delivered pack cannot do, nobody here does")
	var bare := PackedStringArray()
	var named := PackedStringArray()
	var own := ["game", "props", "scenes", "assets", "textures", "courses"]

	for path in _scripts("res://game") + _scripts("res://props"):
		var lines := FileAccess.get_file_as_string(path).split("\n")

		for index in range(lines.size()):
			var line := lines[index].strip_edges()

			if line.begins_with("#"):
				continue

			if line.begins_with("class_name "):
				named.append("%s:%d" % [path, index + 1])

			for folder in own:
				var needle := "\"res://%s/" % folder

				if line.contains(needle) and not line.contains("Paths.rebase(\"res://%s/" % folder):
					bare.append("%s:%d" % [path, index + 1])

	_check(named.is_empty(), "no class_name anywhere", ", ".join(named))
	_check(bare.is_empty(), "no bare res:// path to this game's own files", ", ".join(bare))

	var root := "res://dot_cloud/someone/mg-wipeout/1.0.0/"
	var once := WoPaths.rebase_onto("res://props/wo_crate.tscn", root)
	_check(once == root + "props/wo_crate.tscn", "a path is rebased onto a mount", once)
	_check(WoPaths.rebase_onto(once, root) == once, "and a rebased path is left alone")
	_finished()


func _scripts(dir_path: String) -> PackedStringArray:
	var out := PackedStringArray()
	var dir := DirAccess.open(dir_path)

	if dir == null:
		return out

	for file in dir.get_files():
		if file.ends_with(".gd"):
			out.append(dir_path.path_join(file))

	for sub in dir.get_directories():
		out.append_array(_scripts(dir_path.path_join(sub)))

	return out


## The formulas an obstacle is, checked where they are pure: no world, no physics.
func _test_formulas() -> void:
	_section("an obstacle is a function of the tick")
	var mover := {"from": Vector3.ZERO, "to": Vector3(0, 0, -6), "period": 4.0, "phase": 0.0}
	_check(is_zero_approx(WoCourse.mover_fraction(mover, 0.0)), "a mover starts at `from`")
	_check(is_equal_approx(WoCourse.mover_fraction(mover, 2.0), 1.0), "and is at `to` half a period on")

	var pusher := {"period": 2.0, "reach": 3.0, "duty": 0.35, "phase": 0.0, "at": Vector3.ZERO,
		"size": Vector3.ONE, "yaw": 0.0}
	_check(is_equal_approx(WoCourse.pusher_extension(pusher, 0.4), 1.0), "a pusher is out after its strike")
	_check(is_zero_approx(WoCourse.pusher_extension(pusher, 1.8)), "and home for the rest, the window a player uses")

	var tiles := {"kind": "tiles", "spec": {"period": 3.0, "down": 0.3, "seed": 5}}
	var down := 0
	var samples := 300

	for i in range(samples):
		if WoCourse.tile_down(tiles, 4, float(i) * 0.01):
			down += 1

	_check(absf(float(down) / float(samples) - 0.3) < 0.04,
		"a tile is gone for its `down` share of the cycle", "%.2f" % (float(down) / float(samples)))
	_check(WoCourse.tile_cycle(tiles["spec"], 1, 0.0) != WoCourse.tile_cycle(tiles["spec"], 2, 0.0),
		"two tiles are at different points in the cycle")

	# The tell: on for the last moments before a drop, and off the rest of the time.
	var warned_before := 0
	var warned_wrongly := 0

	for i in range(1, samples):
		var t := float(i) * 0.01
		var warning := WoCourse.tile_warning(tiles["spec"], 4, t)

		if WoCourse.tile_down(tiles, 4, t) and not WoCourse.tile_down(tiles, 4, t - 0.01) \
				and WoCourse.tile_warning(tiles["spec"], 4, t - 0.02) > 0.0:
			warned_before += 1

		if warning > 0.0 and WoCourse.tile_down(tiles, 4, t):
			warned_wrongly += 1

	_check(warned_before > 0, "a tile warns just before it drops", "%d drops warned" % warned_before)
	_check(warned_wrongly == 0, "and never while it is already gone")
	_finished()


# --- A world --------------------------------------------------------------------

func _test_world_builds() -> void:
	_section("a world builds its course and puts everybody on the start pad")
	var game := await _world()
	_check(game.stage != null and game.stage.is_course(), "the stage is a course")
	_check(game.stage.pieces.size() == (game.course_doc["pieces"] as Array).size(),
		"every piece in the document was built", "%d" % game.stage.pieces.size())

	var a := game.add_player(&"u1", "Ada")
	var b := game.add_player(&"u2", "Bo")
	_check(a.team != b.team and a.team >= WoGame.SOLO_SIDE_BASE, "solo players are each their own side",
		"%d, %d" % [a.team, b.team])

	await _step(game, 4)
	var start: Vector3 = game.course_doc["start"]["at"]
	_check(absf(a.controller.state.position.y - start.y) < 0.6 and a.controller.state.position.distance_to(start) < 6.0,
		"a joiner stands on the start pad", str(a.controller.state.position))
	_check(a.controller.state.position.distance_to(b.controller.state.position) > 1.0,
		"two joiners are not put inside each other")
	_finished()


func _test_the_gate() -> void:
	_section("the start gate holds through the countdown, and drops")
	var game := await _world(func(c: WoConfig) -> void: c.countdown_seconds = 1.5)
	var runner := game.add_player(&"u1", "Ada")
	var _other := game.add_player(&"u2", "Bo")
	game.start()
	await _step(game, 2)
	_check(game.phase == WoGame.Phase.COUNTDOWN, "a round starts with the countdown")
	_check(game.stage.gate_closed, "the gate is up")

	var start: Vector3 = game.course_doc["start"]["at"]
	await _hold_for(game, runner, Vector2(0, 1), 0.0, int(1.2 * TICK_RATE))
	_check(runner.controller.state.position.z > start.z - 4.6,
		"running at it during the countdown goes nowhere past it", "z %.2f" % runner.controller.state.position.z)

	await _hold_for(game, runner, Vector2(0, 1), 0.0, int(1.0 * TICK_RATE))
	_check(game.phase == WoGame.Phase.COURSE and not game.stage.gate_closed, "then it drops")
	_check(runner.controller.state.position.z < start.z - 5.0, "and the runner is through",
		"z %.2f" % runner.controller.state.position.z)
	_finished()


func _test_the_carry() -> void:
	_section("a mover carries whoever is standing on it")
	var game := await _world()
	var rider := game.add_player(&"u1", "Ada")
	var mover := _piece(game, "mover")
	_check(not mover.is_empty(), "the practice course has a mover")

	var spec: Dictionary = mover["spec"]
	var period := float(spec["period"])
	# A tick where the mover is at its `from` end, so the next half period carries it to `to`.
	var tick := int(roundf(period * float(TICK_RATE))) * 4
	game._tick = tick - 1
	game.stage.pose_at(tick)
	var top := (spec["from"] as Vector3) + Vector3(0, (spec["size"] as Vector3).y * 0.5 + 0.05, 0)
	rider.place_at(top, 0.0)
	await _step(game, 6)
	var before := rider.controller.state.position
	await _step(game, int(period * 0.5 * TICK_RATE) - 6)
	var after := rider.controller.state.position
	var travelled := Vector2(after.x - before.x, after.z - before.z).length()
	var track := (spec["from"] as Vector3).distance_to(spec["to"])
	_check(travelled > track * 0.85, "standing still, the rider went most of the track",
		"%.2f of %.2f m" % [travelled, track])
	_check(after.y > (spec["from"] as Vector3).y - 0.2, "and is still on it", "y %.2f" % after.y)
	_finished()


func _test_the_turntable() -> void:
	_section("a turntable carries along the arc, not off the edge")
	var game := await _world(func(c: WoConfig) -> void: pass, _turntable_course())
	var rider := game.add_player(&"u1", "Ada")
	var _other := game.add_player(&"u2", "Bo")
	var disc := _piece(game, "turntable")
	var centre: Vector3 = disc["spec"]["at"]
	rider.place_at(centre + Vector3(2.5, 0.35, 0.0), 0.0)
	await _step(game, 4)
	var start_radius := Vector2(rider.controller.state.position.x - centre.x, rider.controller.state.position.z - centre.z).length()
	var start_angle := atan2(rider.controller.state.position.z - centre.z, rider.controller.state.position.x - centre.x)
	await _step(game, TICK_RATE * 3)
	var at := rider.controller.state.position
	var radius := Vector2(at.x - centre.x, at.z - centre.z).length()
	var angle := atan2(at.z - centre.z, at.x - centre.x)
	_check(absf(radius - start_radius) < 0.15, "the radius held over three seconds",
		"%.2f -> %.2f m" % [start_radius, radius])
	_check(absf(angle_difference(start_angle, angle)) > 0.5, "and the rider went round",
		"%.2f rad" % absf(angle_difference(start_angle, angle)))
	_finished()


func _test_the_knock() -> void:
	_section("an arm throws whoever it meets, up and away")
	var game := await _world()
	var victim := game.add_player(&"u1", "Ada")
	var spinner := _piece(game, "spinner")
	var spec: Dictionary = spinner["spec"]
	var hub: Vector3 = spec["at"]
	# Standing on the arm's circle, and waiting for it to come round.
	victim.place_at(hub + Vector3(2.6, 0.05, 0.0), 0.0)
	var thrown := false
	var top_speed := 0.0
	var top_lift := 0.0

	for _i in range(TICK_RATE * 4):
		await _step(game, 1)
		var v := victim.controller.state.velocity
		top_speed = maxf(top_speed, Vector2(v.x, v.z).length())
		top_lift = maxf(top_lift, v.y)

		if victim.knocks > 0:
			thrown = true

	_check(thrown, "the arm came round and threw them", "%d knocks" % victim.knocks)
	_check(top_speed >= game.config.knock_min_speed - 0.01, "at least the floor speed",
		"%.1f m/s" % top_speed)
	_check(top_lift >= game.config.knock_lift - 0.5, "and up", "%.1f m/s" % top_lift)
	_finished()


func _test_ducking() -> void:
	_section("a high arm passes over somebody crouching under it")
	var game := await _world(func(c: WoConfig) -> void: pass, _high_arm_course())
	var standing := game.add_player(&"u1", "Ada")
	var crouching := game.add_player(&"u2", "Bo")
	var hub: Vector3 = _piece(game, "spinner")["spec"]["at"]
	standing.place_at(hub + Vector3(2.5, 0.05, 0.0), 0.0)
	crouching.place_at(hub + Vector3(-2.5, 0.05, 0.0), 0.0)
	var duck := DotFpsCommand.new()
	duck.set_button(DotFpsCommand.BUTTON_CROUCH, true)

	for _i in range(TICK_RATE * 3):
		crouching.controller.apply_command(duck.duplicate_command())
		standing.controller.apply_command(DotFpsCommand.new())
		await _step(game, 1)

	_check(standing.knocks > 0, "standing, it hit them", "%d" % standing.knocks)
	_check(crouching.knocks == 0, "crouched, it did not", "%d" % crouching.knocks)
	_finished()


func _test_a_fall() -> void:
	_section("falling in is a restart from the last checkpoint, not a death")
	var game := await _world()
	var runner := game.add_player(&"u1", "Ada")
	var _other := game.add_player(&"u2", "Bo")
	game.start()
	await _step(game, int((game.config.countdown_seconds + 0.2) * TICK_RATE))

	var checkpoint: Dictionary = game.course_doc["checkpoints"][0]
	runner.place_at(checkpoint["at"], 0.0)
	await _step(game, 3)
	_check(runner.checkpoint == 0, "standing in the checkpoint crosses it")

	runner.place_at(Vector3(30.0, 2.0, -10.0), 0.0)
	await _step(game, TICK_RATE * 2)
	_check(runner.falls == 1, "into the water is one fall", "%d" % runner.falls)
	_check(runner.is_alive(), "and nobody died")
	_check(runner.controller.state.position.distance_to(checkpoint["at"]) < 4.0,
		"they are back at the checkpoint", str(runner.controller.state.position))
	_finished()


func _test_a_bot_runs_the_course() -> void:
	_section("a stand-in runs the practice course to the finish, on its route")
	var game := await _world(func(c: WoConfig) -> void:
		c.bot_fumble_chance = 0.0
		c.countdown_seconds = 0.5
	)
	var bot := game.add_player(&"u900000", "Bot")
	bot.is_bot = true
	var other := game.add_player(&"u2", "Bo")
	game.start()
	var finished_at := -1.0

	for i in range(TICK_RATE * 40):
		other.controller.apply_command(DotFpsCommand.new())
		await _step(game, 1)

		if bot.finished:
			finished_at = game.course_elapsed
			break

	_check(bot.finished, "it finished", "%d falls, checkpoint %d, at %s" % [
		bot.falls, bot.checkpoint, bot.controller.state.position])
	_check(bot.place == 1, "first", "#%d" % bot.place)
	_check(finished_at > 0.0 and finished_at < 30.0, "inside thirty seconds", "%.1f s" % finished_at)
	_finished()


func _test_one_finisher_wins() -> void:
	_section("one side across the line wins the round outright")
	var game := await _world(func(c: WoConfig) -> void: c.countdown_seconds = 0.2; c.course_seconds = 12.0)
	var winner := game.add_player(&"u1", "Ada")
	var _loser := game.add_player(&"u2", "Bo")
	var ended: Array = []
	game.round_over.connect(func(n: int, w: int, why: String) -> void: ended.append([n, w, why]))
	game.start()
	await _step(game, int(0.4 * TICK_RATE))
	var finish: Dictionary = game.course_doc["finish"]
	winner.place_at(finish["at"], 0.0)
	await _step(game, 3)
	_check(winner.finished and winner.place == 1, "crossing the finish finishes them")

	await _step(game, int(13.0 * TICK_RATE))
	_check(ended.size() == 1, "the round ended when the course closed", "%d" % ended.size())
	_check(not ended.is_empty() and int(ended[0][1]) == winner.team, "and their side won",
		str(ended[0]) if not ended.is_empty() else "")
	_check(game.stage.is_course(), "with no final death", str(game.stage.id()))
	_finished()


func _test_the_final_death() -> void:
	_section("two sides across the line fight a final death in a drawn arena")
	var game := await _world(func(c: WoConfig) -> void:
		c.countdown_seconds = 0.2
		c.handover_seconds = 0.5
		c.finale_props_per_side = 4
		c.finale_weapons_per_side = 2
	)
	var a := game.add_player(&"u1", "Ada")
	var b := game.add_player(&"u2", "Bo")
	var c := game.add_player(&"u3", "Cy")
	var ended: Array = []
	game.round_over.connect(func(n: int, w: int, why: String) -> void: ended.append([n, w, why]))
	game.start()
	await _step(game, int(0.4 * TICK_RATE))
	var finish: Dictionary = game.course_doc["finish"]
	a.place_at(finish["at"], 0.0)
	await _step(game, 2)
	b.place_at(finish["at"], 0.0)
	await _step(game, 2)
	_check(a.finished and b.finished and not c.finished, "two finished, one did not")

	# Nobody left on the course but Cy, so the course stays open: Cy is still running.
	_check(game.phase == WoGame.Phase.COURSE, "the course stays open while somebody is on it")

	# Close it by the clock, with Cy still on the course.
	game.course_elapsed = game.course_limit()
	await _step(game, 2)
	_check(game.phase == WoGame.Phase.HANDOVER, "the course closed into a handover")
	_check(game.stage.is_arena(), "the stage is an arena now", str(game.stage.id()))
	_check(not a.watching and not b.watching and c.watching, "the finishers fight; the other watches")
	_check(a.health.invulnerable and b.health.invulnerable, "nobody can be hurt during the handover")

	var gallery: Dictionary = game.arena_doc["gallery"]
	_check(c.controller.state.position.distance_to(gallery["at"]) < 10.0, "the watcher is in the gallery")
	_check(a.controller.state.position.distance_to(b.controller.state.position) > 4.0,
		"the two sides start apart", "%.1f m" % a.controller.state.position.distance_to(b.controller.state.position))
	_check(game.props.world_count() > 0, "props were dropped in", "%d" % game.props.world_count())
	_check(game.pickups.size() > 0, "weapons were laid out", "%d" % game.pickups.size())

	await _step(game, int(0.6 * TICK_RATE))
	_check(game.phase == WoGame.Phase.FINALE and not a.health.invulnerable, "then the final death begins")

	# A weapon picked up off the floor.
	var pickup_id: int = game.pickups.keys()[0]
	var pickup: Dictionary = game.pickups[pickup_id]
	a.place_at((pickup["at"] as Vector3) - Vector3(0, 0.6, 0), 0.0)
	await _step(game, 3)
	_check(a.weapons != null and not game.pickups.has(pickup_id), "standing on a weapon picks it up")

	# A prop picked up and thrown at somebody.
	var prop: DotPropInstance = game.props.all_props()[0]
	var body := prop.body()
	body.global_position = b.controller.state.position + Vector3(0, 1.0, -3.0)
	body.linear_velocity = Vector3.ZERO
	var throw_from := body.global_position + Vector3(0, -0.6, -2.0)
	b.place_at(b.controller.state.position, 180.0)
	game._thrown[prop.instance_id] = {"by": a.player_id, "until": game.current_tick() + 120}
	body.linear_velocity = (b.controller.state.position + Vector3(0, 0.9, 0) - body.global_position).normalized() * 16.0
	var before := b.health.health
	await _step(game, 20)
	_check(b.health.health < before, "a thrown prop that meets somebody hurts them",
		"%.0f -> %.0f" % [before, b.health.health])
	var _unused := throw_from

	# The last one standing.
	var damage := DotDamage.make(a.entity_id, b.entity_id, 500.0, null)
	damage.tick = game.current_tick()
	var _applied := game.combat.apply_damage(damage)
	await _step(game, 3)
	_check(ended.size() == 1 and int(ended[0][1]) == a.team, "the last side standing wins",
		str(ended[0]) if not ended.is_empty() else "")
	_finished()


func _test_nobody_finishes() -> void:
	_section("nobody across the line: whoever got furthest wins")
	var game := await _world(func(c: WoConfig) -> void: c.countdown_seconds = 0.2; c.course_seconds = 10.0)
	var far := game.add_player(&"u1", "Ada")
	var _near := game.add_player(&"u2", "Bo")
	var ended: Array = []
	game.round_over.connect(func(n: int, w: int, why: String) -> void: ended.append([n, w, why]))
	game.start()
	await _step(game, int(0.4 * TICK_RATE))
	var checkpoint: Dictionary = game.course_doc["checkpoints"][0]
	far.place_at(checkpoint["at"], 0.0)
	await _step(game, int(11.0 * TICK_RATE))
	_check(ended.size() == 1 and int(ended[0][1]) == far.team, "the one who reached a checkpoint won",
		str(ended[0]) if not ended.is_empty() else "")
	_finished()


# --- Helpers ------------------------------------------------------------------------

func _test_knocks_hurt() -> void:
	_section("on the course a knock hurts, a bad one is fatal, a checkpoint heals")
	var game := await _world(func(c: WoConfig) -> void:
		c.wind_chance = 0.0
		c.storm_chance = 0.0)
	var victim := game.add_player(&"u1", "Ada")
	var other := game.add_player(&"u2", "Bo")
	game.start()
	await _step(game, int((game.config.countdown_seconds + 0.2) * TICK_RATE))

	var hub: Vector3 = _piece(game, "spinner")["spec"]["at"]
	victim.place_at(hub + Vector3(2.6, 0.05, 0.0), 0.0)
	var before := victim.health.health
	for _i in range(TICK_RATE * 4):
		await _step(game, 1)
		if victim.knocks > 0:
			await _step(game, 1)
			break
	var expected := victim.last_knock_speed * game.config.knock_damage_per_speed
	_check(victim.knocks > 0 and absf((before - victim.health.health) - expected) < 1.0,
		"a knock costs health by how hard it threw them",
		"%.1f lost for a %.1f m/s throw" % [before - victim.health.health, victim.last_knock_speed])

	# Low enough that the next knock is fatal: out for the round, alive in the lounge.
	victim.health.health = 1.0
	victim.place_at(hub + Vector3(2.6, 0.05, 0.0), 0.0)
	var knocks := victim.knocks
	for _i in range(TICK_RATE * 4):
		await _step(game, 1)
		if victim.knocks > knocks:
			await _step(game, 2)
			break
	_check(victim.watching and victim.is_alive(), "a fatal knock takes them out of the round, watching")
	_check(not game._course_is_over() or other.finished, "and the course goes on for the rest")

	other.finished = true
	_check(game._course_is_over(), "with everybody finished or out, the course is over")
	other.finished = false

	var checkpoint: Dictionary = game.course_doc["checkpoints"][0]
	other.health.health = 30.0
	other.place_at(checkpoint["at"], 0.0)
	await _step(game, 3)
	_check(other.health.health >= other.health.max_health - 0.01, "a checkpoint heals (%.0f)" % other.health.health)
	_finished()


func _test_the_weather() -> void:
	_section("gusts and lightning are drawn once and computed from the tick")
	var game := await _world(func(c: WoConfig) -> void:
		c.wind_chance = 1.0
		c.storm_chance = 1.0)
	var doc: Dictionary = game.course_doc
	var once := game.draw_weather(doc, DotRandomStream.new(7, &"weather"), 100)
	var twice := game.draw_weather(doc, DotRandomStream.new(7, &"weather"), 100)
	_check(once == twice, "the same stream draws the same weather")
	_check((once["gusts"] as Array).size() > 0 and (once["strikes"] as Array).size() == game.config.storm_strikes,
		"wind and storm on: gusts and %d strikes" % game.config.storm_strikes)

	# A known plan: one gust east from tick 200 to 600, one strike at the start at tick 300.
	var start: Vector3 = doc["start"]["at"]
	var planned := doc.duplicate(true)
	planned["weather"] = {
		"gusts": [{"from": 200, "to": 600, "dx": 1.0, "dz": 0.0, "strength": 10.0}],
		"strikes": [{"tick": 300, "x": start.x, "y": start.y, "z": start.z, "radius": 3.0}],
	}
	var _built := game.build_stage(planned)
	_check(game.stage.wind(150) == Vector3.ZERO and game.stage.wind(400).x > 9.0,
		"the wind blows only inside its gust (%.1f at 400)" % game.stage.wind(400).x)
	_check(game.stage.is_stormy() and not game.stage.strike_at(300).is_empty(), "the course knows its storm")
	_check(game.stage.strike(start, 300) != Vector3.ZERO and game.stage.strike(start, 301) == Vector3.ZERO,
		"a strike throws whoever is under it, on its tick only")
	_check(game.stage.strike(start + Vector3(10.0, 0.0, 0.0), 300) == Vector3.ZERO, "and nobody further away")
	_finished()


func _piece(game: WoGame, kind: String) -> Dictionary:
	for piece in game.stage.pieces:
		if str(piece["kind"]) == kind:
			return piece

	return {}


## Holds a direction for [param ticks]. Applied every tick, because the motor repeats a
## starved tick's view and buttons but drops its movement.
func _hold_for(game: WoGame, player: WoPlayer, move: Vector2, yaw: float, ticks: int) -> void:
	for _i in range(ticks):
		var command := DotFpsCommand.new()
		command.move = move
		command.yaw = yaw
		player.controller.apply_command(command)
		await _step(game, 1)


func _turntable_course() -> Dictionary:
	var doc := WoCatalogue.practice().duplicate(true)
	doc["id"] = "test_turntable"
	(doc["pieces"] as Array).append({"kind": "turntable", "at": [20.0, -0.3, -10.0], "radius": 4.0,
		"thickness": 0.6, "speed": 40.0})
	return doc


func _high_arm_course() -> Dictionary:
	var doc := WoCatalogue.practice().duplicate(true)
	doc["id"] = "test_high_arm"
	doc["pieces"] = [
		{"kind": "box", "at": [20.0, -0.5, -10.0], "size": [10.0, 1.0, 10.0]},
		{"kind": "spinner", "at": [20.0, 0.0, -10.0], "arm_length": 4.0, "arm_height": 1.5,
			"arm_thickness": 0.3, "speed": 90.0, "arms": 1},
	]
	return doc


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


## A world on the practice course (or on [param course]), stepped by hand.
##
## [b]The previous world is freed first, and keeping it was a failure that looked like the
## game's.[/b] Every world here is a child of this node, so all of them share ONE physics
## space — and every course is built at the origin. A world left standing from an earlier
## section kept its start gate closed exactly where the next world's runner had to go, and
## "the runner is through" failed at the gate's face with the new world's own gate eighty
## metres down.
func _world(configure: Callable = Callable(), course: Dictionary = {}) -> WoGame:
	for old in _worlds.duplicate():
		await _dispose(old)

	var config := WoConfig.new()
	config.warmup_seconds = 0.0
	config.intermission_seconds = 0.0
	config.minimum_players = 0
	config.course_ids = PackedStringArray(["wo_practice"])
	config.arena_ids = PackedStringArray(["wo_practice_arena"])
	config.keep_progress = true

	if configure.is_valid():
		configure.call(config)

	var game := WoGame.new()
	game.name = "World%d" % _worlds.size()
	game.config = config
	game.tick_rate = TICK_RATE
	game.authoritative = true
	game.register_service = false
	add_child(game)
	game.set_physics_process(false)
	_worlds.append(game)

	if not course.is_empty():
		var _built := game.build_stage(course)

	# Two frames, so every collider is in the physics space before anything is asserted.
	await _physics_frame()
	await _physics_frame()
	return game


func _step(game: WoGame, ticks: int) -> void:
	for _i in range(ticks):
		game.simulate(TICK)
		await _physics_frame()


func _physics_frame() -> void:
	await get_tree().physics_frame


func _dispose(game: WoGame) -> void:
	_worlds.erase(game)

	if not is_instance_valid(game):
		return

	remove_child(game)
	game.free()
	await get_tree().process_frame
