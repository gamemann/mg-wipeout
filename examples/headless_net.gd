extends Node

const WoCatalogue := preload("../game/wo_catalogue.gd")
const WoConfig := preload("../game/wo_config.gd")
const WoCourseDoc := preload("../game/wo_course_doc.gd")
const WoEvents := preload("../game/net/wo_events.gd")
const WoGame := preload("../game/wo_game.gd")
const WoNetBridge := preload("../game/net/wo_net_bridge.gd")
const WoPlayer := preload("../game/wo_player.gd")

## The real path minus the socket: two worlds, two managers, two bridges, two links with the
## RPC replaced by a queue — so the codec, the seal, the snapshots, the prediction and the
## reconciliation all run, in one process, in two physics worlds.
##
## [b]What this suite is for is the claim the whole game rests on:[/b] a course is sent once,
## as a document, and after that the client and the server agree about every obstacle on it
## at every tick without one more byte about any of them. If that is false, a knock the
## client predicts is a knock the server never decided, and the player is corrected through
## an arm. So this asserts it from both ends — the same transform at the same tick, and a
## knock predicted and decided — and then everything else that crosses: progress, the arena,
## the weapons on its floor, the result.
##
## Sections and checks are both counted; mg-smash-copter's notes say why the second matters.

const SECTIONS := 10
const CHECKS := 46

const CLIENT_PEER := 7
const SESSION := 42
const SERVER_TICK_RATE := 64
const CLIENT_ENGINE_TICK_RATE := 30
const SNAPSHOT_RATE := 30
const INPUT_LEAD := 3

var _passed := 0
var _failed := 0
var _sections_entered := 0
var _sections_finished := 0
var _failures := PackedStringArray()

var _server_game: WoGame = null
var _client_game: WoGame = null
var _server_net: DotNetManager = null
var _client_net: DotNetManager = null
var _server_bridge: WoNetBridge = null
var _client_bridge: WoNetBridge = null
var _stand_in: WoPlayer = null

var _to_client: Array = []
var _to_server: Array = []
var _tick: int = 0

## What the client was told, by kind, so a section can ask whether an event arrived.
var _heard: Dictionary = {}


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run.call_deferred()


func _run() -> void:
	print("wipeout over the wire")
	print("")

	_test_the_codec()

	if await _build():
		await _test_a_client_joins()
		await _test_the_course_arrives()
		await _test_obstacles_agree()
		await _test_a_knock_is_predicted()
		await _test_the_local_player_is_predicted()
		await _test_progress_crosses()
		await _test_the_final_death_crosses()
		await _test_leaving()

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


# --- The codec ------------------------------------------------------------------

## Every encoder against its decoder. Nothing checks that two ends of a serialisation are
## inverses for you: dot-moderation once wrote "voice muted" and read back a warning.
func _test_the_codec() -> void:
	_section("every event decodes to what was encoded")

	var hello := WoEvents.read_hello(DotNetReader.new(
		WoEvents.write_hello(SESSION, 64, 1234, 0, 4.0, 210.0, 4.0, 100.0)))
	_check(bool(hello["ok"]) and int(hello["player_id"]) == SESSION and int(hello["team_count"]) == 0
		and absf(float(hello["course_seconds"]) - 210.0) < 0.1
		and absf(float(hello["countdown_seconds"]) - 4.0) < 0.01, "HELLO", str(hello))

	var doc := WoCatalogue.practice()
	var stage := WoEvents.read_stage(DotNetReader.new(WoEvents.write_stage(WoCourseDoc.encode(doc))))
	var decoded := WoCourseDoc.decode(stage["encoded"]) if bool(stage["ok"]) else DotResult.fail(DotError.CODE_PARSE, "no stage")
	_check(decoded.ok and WoCourseDoc.digest(decoded.value) == WoCourseDoc.digest(doc), "STAGE carries the document whole")

	var join := WoEvents.read_join(DotNetReader.new(WoEvents.write_join(SESSION, 9, "Ada", 101, null)))
	_check(bool(join["ok"]) and int(join["team"]) == 101,
		"JOIN carries a solo side, numbered past any team", str(join.get("team")))

	var round_info := WoEvents.read_round(DotNetReader.new(WoEvents.write_round(3, false, 104, "Bo won the final death")))
	_check(bool(round_info["ok"]) and int(round_info["winner"]) == 104 and str(round_info["why"]) == "Bo won the final death",
		"ROUND carries the winning side and the sentence")

	var moved := WoEvents.read_progress(DotNetReader.new(WoEvents.write_progress(SESSION, WoEvents.Progress.FINISHED, 2, 61.25)))
	_check(bool(moved["ok"]) and int(moved["kind"]) == WoEvents.Progress.FINISHED and int(moved["value"]) == 2
		and absf(float(moved["seconds"]) - 61.25) < 0.01, "PROGRESS", str(moved))

	var pickup := WoEvents.read_pickup(DotNetReader.new(WoEvents.write_pickup(5, &"shotgun", Vector3(3, 0.7, -12))))
	_check(bool(pickup["ok"]) and pickup["weapon_id"] == &"shotgun"
		and (pickup["position"] as Vector3).distance_to(Vector3(3, 0.7, -12)) < 0.01, "PICKUP")

	var gone := WoEvents.read_pickup_gone(DotNetReader.new(WoEvents.write_pickup_gone(5, SESSION)))
	_check(bool(gone["ok"]) and int(gone["by"]) == SESSION, "PICKUP_GONE")

	var clock := WoEvents.read_clock(DotNetReader.new(WoEvents.write_clock(2, 12.5, 40.25, WoGame.Phase.FINALE, 3, 2, true)))
	_check(bool(clock["ok"]) and int(clock["phase"]) == WoGame.Phase.FINALE
		and absf(float(clock["course_elapsed"]) - 40.25) < 0.1 and int(clock["finished"]) == 3, "CLOCK", str(clock))
	_finished()


# --- Bringing both halves up ---------------------------------------------------------

func _build() -> bool:
	_section("bringing both halves up")
	var failed_before := _failed

	var server_side := Node.new()
	server_side.name = "ServerSide"
	add_child(server_side)

	# The client's own physics space: two processes would be two worlds, and one world holding
	# both copies of a course is two of every collider in the same cubic metres.
	var client_view := SubViewport.new()
	client_view.name = "ClientView"
	client_view.own_world_3d = true
	client_view.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(client_view)

	var client_side := Node.new()
	client_side.name = "ClientSide"
	client_view.add_child(client_side)

	_server_game = _make_game(true, server_side)
	_client_game = _make_game(false, client_side)
	await get_tree().process_frame

	_check(_server_game.get_world_3d() != _client_game.get_world_3d(), "two physics worlds, as two processes would have")
	_check(_client_game.stage.doc.is_empty() and _client_game.catalogue == null,
		"the client has no course and reads no course files; it will be sent one")

	Engine.physics_ticks_per_second = CLIENT_ENGINE_TICK_RATE

	_server_net = _make_manager(true, &"server", 1, server_side, SERVER_TICK_RATE)
	_client_net = _make_manager(false, &"client", CLIENT_PEER, client_side, CLIENT_ENGINE_TICK_RATE)

	_server_bridge = WoNetBridge.new()
	_server_bridge.name = "Bridge"
	server_side.add_child(_server_bridge)

	_client_bridge = WoNetBridge.new()
	_client_bridge.name = "Bridge"
	client_side.add_child(_client_bridge)

	var attached := _server_bridge.attach(_server_game, _server_net)
	var client_attached := _client_bridge.attach(_client_game, _client_net)
	_check(attached.ok and client_attached.ok, "both bridges attach")

	_server_bridge.open_link(server_side)
	_client_bridge.open_link(client_side)
	_server_net.messages.seal()
	_client_net.messages.seal()
	_check(_server_net.messages.schema_hash() == _client_net.messages.schema_hash(), "both ends agree on the schema")

	_server_bridge.link.loopback = _on_server_send
	_client_bridge.link.loopback = _on_client_send
	_client_bridge.rtt_source = func() -> float: return 40.0

	var _s := _server_net.start()
	var _c := _client_net.start()

	_client_bridge.stage_received.connect(func(id: StringName, arena: bool) -> void:
		_heard["stage"] = [id, arena])
	_client_bridge.progress_received.connect(func(who: int, kind: int, value: int, seconds: float) -> void:
		_heard["progress_%d" % kind] = [who, value, seconds])
	_client_bridge.pickup_received.connect(func(pickup_id: int, weapon: StringName, at: Vector3) -> void:
		_heard["pickup"] = [pickup_id, weapon, at])
	_client_bridge.round_changed.connect(func(n: int, began: bool, winner: int, why: String) -> void:
		if not began:
			_heard["round_over"] = [n, winner, why])

	_stand_in = _server_bridge.add_bot("Stand-in")
	_check(_stand_in != null and _stand_in.is_bot, "a stand-in is seated before anybody joins")

	# Started AFTER the bridge exists, which is what the module does: a course laid out before
	# anything listened to `world_rebuilt` would be a course no client is ever sent.
	_server_game.start()
	_check(_server_game.stage.is_course(), "the server lays its course out on start")
	_finished()
	return _failed == failed_before


func _test_a_client_joins() -> void:
	_section("a client joins")
	var seated := _server_bridge.add_player(CLIENT_PEER, SESSION, "Ada")
	_check(seated.ok, "the server seats them")
	_client_bridge.ask_ready()
	_exchange()
	_exchange()
	await _steps(6)

	_check(_client_bridge.local_player_id == SESSION, "the client is told who it is")
	_check(_client_game.tick_rate == SERVER_TICK_RATE and _client_game.stage.tick_rate == SERVER_TICK_RATE,
		"it adopts the server's tick rate, and so does its course", "%d / %d" % [_client_game.tick_rate, _client_game.stage.tick_rate])
	_check(_client_game.players.size() == 2, "it has a body for itself and for the stand-in", "%d" % _client_game.players.size())
	var mine := _mine()
	_check(mine != null and _client_game.team_of(mine.player_id) == _server_game.team_of(mine.player_id),
		"and agrees with the server about its own side")
	_finished()


func _test_the_course_arrives() -> void:
	_section("the course arrives, as the document the server built")
	_check(not _client_game.stage.doc.is_empty() and _client_game.stage.is_course(), "the client built a course")
	_check(WoCourseDoc.digest(_client_game.stage.doc) == WoCourseDoc.digest(_server_game.stage.doc),
		"the same document, to the byte", WoCourseDoc.digest(_client_game.stage.doc))
	_check(_client_game.stage.pieces.size() == _server_game.stage.pieces.size(), "every piece", "%d" % _client_game.stage.pieces.size())
	_check(_heard.has("stage") and not bool(_heard["stage"][1]), "and the client said so, as a course")
	_finished()


## The claim: the same tick, the same obstacle, on both ends, and nothing sent about it.
func _test_obstacles_agree() -> void:
	_section("every obstacle is where the server has it, at every tick, with nothing sent")
	var worst := 0.0

	for tick in [0, 17, 64, 300, 1001]:
		_server_game.stage.pose_at(tick)
		_client_game.stage.pose_at(tick)

		for index in range(_server_game.stage.pieces.size()):
			var server_piece: Dictionary = _server_game.stage.pieces[index]
			var client_piece: Dictionary = _client_game.stage.pieces[index]

			if not bool(server_piece["moving"]):
				continue

			var a := _shape_of(server_piece)
			var b := _shape_of(client_piece)
			worst = maxf(worst, a.origin.distance_to(b.origin))

	_check(worst < 0.0001, "the moving pieces agree at five ticks", "worst %.6f m" % worst)

	var limits := Vector3(8.0, 22.0, 5.5)
	var agree := 0
	var asked := 0

	for tick in range(0, 640, 8):
		for at in [Vector3(1.8, 0.0, -21.5), Vector3(-2.0, 0.0, -21.0), Vector3(0.0, 0.0, -38.0)]:
			asked += 1
			if _server_game.stage.knock(at, false, tick, limits) == _client_game.stage.knock(at, false, tick, limits):
				agree += 1

	_check(agree == asked, "and so does every knock asked of them", "%d of %d" % [agree, asked])
	_finished()


func _shape_of(piece: Dictionary) -> Transform3D:
	var node: Node3D = piece["node"]

	match str(piece["kind"]):
		"spinner":
			return (node.get_node(^"Arms") as Node3D).transform
		"pendulum":
			return (node.get_node(^"Arm") as Node3D).transform
		"pusher":
			return (node.get_node(^"Ram") as Node3D).transform
		"tiles":
			return (node.get_child(0) as Node3D).transform
		_:
			return node.transform


## A knock the client predicts is the knock the server decides, so the client is not
## corrected through the arm: both ends count one, and they end up in the same place.
func _test_a_knock_is_predicted() -> void:
	_section("a knock is predicted, and it is the one the server decides")
	await _run_course_open()
	var server_me: WoPlayer = _server_game.players[WoNetBridge.player_key(SESSION)]
	var hub := _spinner_hub(_server_game)
	server_me.place_at(hub + Vector3(2.6, 0.05, 0.0), 0.0)
	var client_before := _mine().knocks
	var server_before := server_me.knocks

	# Two arms at seventy-five degrees a second: one comes round every 2.4 s at the most.
	for _i in range(SERVER_TICK_RATE * 4):
		await _step()

		if server_me.knocks > server_before and _mine().knocks > client_before:
			break

	_check(server_me.knocks > server_before, "the server threw them", "%d" % (server_me.knocks - server_before))
	_check(_mine().knocks > client_before, "and the client, predicting, threw them too", "%d" % (_mine().knocks - client_before))
	await _steps(40)
	var apart := _mine().controller.state.position.distance_to(server_me.controller.state.position)
	_check(apart < 0.6, "and they agree where the flight ended", "%.2f m apart" % apart)
	_finished()


func _test_the_local_player_is_predicted() -> void:
	_section("the local player is predicted, and the server agrees")
	var mine := _mine()
	var server_me: WoPlayer = _server_game.players[WoNetBridge.player_key(SESSION)]
	var start: Vector3 = _server_game.course_doc["checkpoints"][0]["at"]
	server_me.place_at(start, 0.0)
	await _steps(20)
	var before := mine.controller.state.position
	var forward := DotFpsCommand.new()
	forward.move = Vector2(0.0, 1.0)
	await _step(forward)
	_check(mine.controller.state.position.distance_to(before) > 0.01,
		"a key moves the client's own player on the tick it is pressed")
	await _steps(24, forward)
	await _steps(24)
	var apart := mine.controller.state.position.distance_to(server_me.controller.state.position)
	_check(apart < 0.25, "and after running, the two ends agree", "%.3f m" % apart)
	_finished()


func _test_progress_crosses() -> void:
	_section("checkpoints and the finish cross")
	var server_me: WoPlayer = _server_game.players[WoNetBridge.player_key(SESSION)]
	var checkpoint: Dictionary = _server_game.course_doc["checkpoints"][0]
	server_me.place_at(checkpoint["at"], 0.0)
	await _steps(8)
	_check(_heard.has("progress_%d" % WoEvents.Progress.CHECKPOINT), "a checkpoint is announced")
	_check(_mine().checkpoint == 0, "and the client's player has it", "%d" % _mine().checkpoint)

	var finish: Dictionary = _server_game.course_doc["finish"]
	server_me.place_at(finish["at"], 0.0)
	await _steps(8)
	_check(_heard.has("progress_%d" % WoEvents.Progress.FINISHED)
		and int(_heard["progress_%d" % WoEvents.Progress.FINISHED][0]) == SESSION, "the finish is announced, with who")
	_check(_mine().finished, "and the client's player is across")

	# Into the water from the lounge: back to the lounge, and the client is told it was a fall.
	server_me.place_at(Vector3(40.0, 1.0, -30.0), 0.0)
	# Seven metres down to the water is most of a second.
	await _steps(SERVER_TICK_RATE * 2)
	_check(_heard.has("progress_%d" % WoEvents.Progress.FELL), "a fall is announced")
	_finished()


func _test_the_final_death_crosses() -> void:
	_section("the final death crosses: the arena, the floor, the gallery, the result")
	# The stand-in across too, so two sides finished and the course closes into a fight.
	_server_game._finish_count += 1
	_stand_in.finished = true
	_stand_in.place = _server_game._finish_count
	_server_game.course_elapsed = _server_game.course_limit()
	await _steps(6)
	_check(_server_game.phase == WoGame.Phase.HANDOVER, "the server is in a handover")
	_check(_client_game.stage.is_arena() and WoCourseDoc.digest(_client_game.stage.doc) == WoCourseDoc.digest(_server_game.stage.doc),
		"the client built the same arena")
	_check(_heard.has("pickup") and _client_game.pickups.size() == _server_game.pickups.size(),
		"the weapons on its floor arrived", "%d" % _client_game.pickups.size())

	await _steps(40)
	var bodies := int(_client_bridge.describe()["bodies"])
	_check(bodies == _server_game.props.world_count() and bodies > 0, "and every prop", "%d" % bodies)
	_check(not _mine().watching, "a finisher is fighting, not watching")

	# The gun in their hand, as somebody else draws it. Armed on the server as a pickup arms
	# them, and announced as the module announces it (this suite has no module); the client's
	# copy of this player, drawn as a watcher would, holds it at the end of its right arm.
	var server_me: WoPlayer = _server_game.players[WoNetBridge.player_key(SESSION)]
	var _armed := _server_game.arm(server_me, &"pistol")
	_server_bridge.announce_armed(server_me.player_id, &"pistol")
	await _steps(4)
	var copy := _mine()
	var _shown := copy.present_body(false, copy.global_position, Color.WHITE)
	var hand := copy.figure.attachment(&"right_hand") if copy.figure != null else null
	_check(
		copy.figure != null and copy.figure.holding == &"pistol" and copy.figure.held != null
			and copy.figure.held.equipped() == &"pistol"
			and hand != null and String(hand.get_parent().name) == "arm-right",
		"a watcher draws the weapon in their right hand",
		"%s drawn, dealt %s" % [
			String(copy.figure.holding) if copy.figure != null else "-", str(copy.dealt)
		]
	)

	await _steps(int(_server_game.config.handover_seconds * SERVER_TICK_RATE) + 4)
	_check(_client_game.phase == WoGame.Phase.FINALE, "the client knows the fight is on")

	var damage := DotDamage.make(0, _stand_in.entity_id, 500.0, null)
	damage.tick = _tick
	var _applied := _server_game.combat.apply_damage(damage)
	await _steps(6)
	_check(_heard.has("round_over") and int(_heard["round_over"][1]) == _server_game.team_of(WoNetBridge.player_key(SESSION)),
		"the last one standing wins, and the client is told who", str(_heard.get("round_over")))
	_check(_heard.has("round_over") and str(_heard["round_over"][2]).contains("final death"),
		"with the server's own sentence")
	_finished()


func _test_leaving() -> void:
	_section("leaving")
	_server_bridge.remove_peer(CLIENT_PEER)
	await _steps(4)
	_check(not _server_game.players.has(WoNetBridge.player_key(SESSION)), "the server lets them go")
	_check(not _client_game.players.has(WoNetBridge.player_key(SESSION)) or _server_bridge.describe()["ready_peers"] == 0,
		"and stops talking to them")
	_finished()


# --- Helpers --------------------------------------------------------------------

func _mine() -> WoPlayer:
	return _client_game.players.get(WoNetBridge.player_key(SESSION))


func _spinner_hub(game: WoGame) -> Vector3:
	for piece in game.stage.pieces:
		if str(piece["kind"]) == "spinner":
			return piece["spec"]["at"]
	return Vector3.ZERO


## Steps until the course is open, so the gate is down and hazards count.
func _run_course_open() -> void:
	for _i in range(SERVER_TICK_RATE * 8):
		if _server_game.phase == WoGame.Phase.COURSE:
			return
		await _step()


func _make_game(server: bool, parent: Node) -> WoGame:
	var config := WoConfig.new()
	config.warmup_seconds = 0.0
	config.intermission_seconds = 0.0
	config.countdown_seconds = 0.5
	config.handover_seconds = 0.5
	config.minimum_players = 0
	config.keep_progress = false
	config.course_ids = PackedStringArray(["wo_practice"])
	config.arena_ids = PackedStringArray(["wo_practice_arena"])

	var game := WoGame.new()
	game.name = "World"
	game.config = config
	game.authoritative = server
	game.tick_rate = SERVER_TICK_RATE if server else CLIENT_ENGINE_TICK_RATE
	game.register_service = false
	parent.add_child(game)
	game.set_physics_process(false)
	return game


func _make_manager(server: bool, scope: StringName, peer_id: int, parent: Node, tick_rate: int) -> DotNetManager:
	var manager := DotNetManager.new()
	manager.name = "Server" if server else "Client"
	manager.is_server = server
	manager.local_peer_id = peer_id
	manager.service_scope = scope
	manager.auto_tick = false
	manager.config_file = ""

	var config := DotNetConfig.new()
	config.tick_rate = tick_rate
	config.snapshot_rate = SNAPSHOT_RATE
	config.enable_prediction = true
	config.enable_lag_compensation = false
	config.max_entities_per_snapshot = 192
	config.world_extent = WoGame.NET_WORLD_EXTENT
	manager.config = config

	parent.add_child(manager)
	var _ready_now := manager.setup()
	return manager


func _on_server_send(method: StringName, peer_id: int, payload: PackedByteArray) -> void:
	if peer_id != 0 and peer_id != CLIENT_PEER:
		return

	_to_client.append({"method": method, "payload": payload})


func _on_client_send(method: StringName, _peer_id: int, payload: PackedByteArray) -> void:
	_to_server.append({"method": method, "payload": payload})


func _flush() -> void:
	var to_client := _to_client.duplicate()
	var to_server := _to_server.duplicate()
	_to_client.clear()
	_to_server.clear()

	for entry in to_client:
		_client_bridge.link.deliver(entry["method"], 1, entry["payload"])

	for entry in to_server:
		_server_bridge.link.deliver(entry["method"], CLIENT_PEER, entry["payload"])


func _exchange() -> void:
	_flush()
	_flush()


## One tick on both ends, with a real physics frame between them: the props are rigid bodies,
## and a rigid body moves on the physics frame and nowhere else.
func _step(command: DotFpsCommand = null) -> void:
	_tick += 1
	var _ticks := _client_net.clock.advance(1.0 / float(maxi(_client_game.tick_rate, 1)))
	_server_bridge.server_tick(_tick)
	_flush()
	_client_bridge.client_tick(_tick + INPUT_LEAD, command if command != null else DotFpsCommand.new())
	_flush()
	await get_tree().physics_frame


func _steps(count: int, command: DotFpsCommand = null) -> void:
	for _i in range(count):
		await _step(command)


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
