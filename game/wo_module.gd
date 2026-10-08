extends DotGameModule

const WoNetBridge := preload("net/wo_net_bridge.gd")
const WoServices := preload("wo_services.gd")

const WoGame := preload("wo_game.gd")
const WoPlayer := preload("wo_player.gd")
const WoAvatars := preload("wo_avatars.gd")

## This game, as a module a dedicated server loads.
##
## [b]A hundred and forty lines, against the five hand-written modules' 837 to 1,816.[/b]
## [DotGameModule] holds the netcode and its four load-bearing constants, the bridge, the
## message seal, the identity layer, the roster, the authoritative tick and a teardown in
## the reverse order. Two of those five hand-written copies had the same line wrong and
## nobody could ever join those servers. What is left here is what is actually this game's:
## the cvars an operator turns between rounds, the two console commands, and the rule that
## keeps enough people in a round for one to happen.
##
## [b]No `class_name`, and that is a requirement rather than a style.[/b]
## [method DotModuleHost.load_module] takes a PATH and constructs the module itself — it
## must, because that is the shape that lets an operator name one in a config file — and a
## module delivered inside a dot-cloud pack cannot have a `class_name` at all: a mounted
## pack's globals are not registered in the host.
##
## [codeblock]
## server.modules.load_module("res://game/wo_module.gd")
## [/codeblock]

# [b]No `const CHANNEL` here, and its absence is the point.[/b] [DotGameModule] already
# declares one and GDScript refuses to let a subclass redeclare it — which is the right
# refusal: a module logs through [method DotModule.log_info], which stamps the module's own
# name, so a second channel would split one module's records across two places an operator
# has to know to turn up separately.

## Seconds between checks of how many people are in the round.
const ROSTER_INTERVAL := 2.0

## Where the services keep punishments. Empty is [DotGameServices]'s own default,
## `user://wipeout_punishments.json` — the store a real server enforces.
##
## [b]Static, because nothing holds this module before it exists[/b]: dot-server constructs
## it from a path inside `load_module`, so there is no instance for a host to set a field on
## first. `examples/dedicated.tscn` points it at a directory of its own; before it could,
## every run appended the live tools' audit warnings to the real store, 106 of them by the
## time anybody counted.
static var punishments_file: String = ""

## The `wo_bots` cvar, held so the tick does not look it up sixty times a second.
var _bots: DotConVar = null

var _since_roster_check: float = 0.0

## How many stand-ins this module has put in, so it can take them out again.
var _bot_ids: Array[StringName] = []


func _module_name() -> String:
	return "wipeout"


func _game_service() -> StringName:
	return WoGame.SERVICE


func _game_missing_hint() -> String:
	return (
		"create an WoGame, add it to the tree and let its _ready() register it under "
		+ "'%s' — a module cannot build the world, because the world outlives it"
		% String(WoGame.SERVICE)
	)


## The netcode's numbers, which are the game's and not the addon's.
##
## Tick rate from the world, so `sv_tickrate` reaches it: the server sets the engine's
## physics rate from that cvar at boot, the world is built after the server and reads it,
## and this reads the world. A number written here instead would be a netcode running at a
## rate the operator did not choose, silently.
func _net_config() -> DotNetConfig:
	var config := DotNetConfig.new()
	config.tick_rate = (game as WoGame).tick_rate
	config.snapshot_rate = WoGame.NET_SNAPSHOT_RATE
	config.world_extent = WoGame.NET_WORLD_EXTENT
	config.enable_prediction = true
	# [b]On, and the two callables that make it real are wired by the bridge.[/b] It was off
	# for as long as they were not: a flag reported as enabled with nothing behind it is
	# worse than one that is off, because the first reader to trust it loses an afternoon.
	# See [method WoNetBridge._wire_lag_compensation].
	#
	# The showdown is a fight at range with rifles, which is the ordinary reason to want it.
	# The less obvious one is that this game's hitboxes stand on a floor that was in a
	# different place a hundred milliseconds ago — so rewinding a player rewinds where the
	# platform had carried them to, which nothing else could reconstruct.
	config.enable_lag_compensation = true
	# A dozen platforms, up to a hundred and ten props, a couple of choppers and everybody
	# playing — all of it always relevant, because the map is open air and a player can see
	# the whole of it.
	config.max_entities_per_snapshot = 192
	return config


func _make_bridge() -> Node:
	return WoNetBridge.new()


## Chat, voice and moderation, over [DotGameServices].
##
## [b]The bridge is handed over as the link, and that is the whole of the wiring.[/b] A chat
## line goes out through `send_chat` and a voice frame through `send_voice`, both on this
## game's own wire. [DotGameModule] does the rest: it assigns the bridge's `voice_relay_fn`,
## checks `check_admission` before seating anybody, and tells the roster to follow this layer
## so a leaver is forgotten by the rate limiter and the voice router together.
func _make_services() -> Node:
	var services := WoServices.new()
	services.bridge = bridge
	services.punishments_file = punishments_file
	return services


## Profiles, avatars and admission: dot-platform's [DotPlatformIdentity] over this game's
## one-slot schema. [DotGameModule] builds it before the services and loads dot-platform's
## own module beside it.
##
## [b]Authentication is not here and was never this game's.[/b] Whether a player is proven
## to be somebody is the host's `dot_auth_server`, the same for every game it runs; what
## this layer does is everything after — a scoped profile, the name on it, and a face.
## With authentication off everybody is a guest with a profile of their own, which is what
## a LAN server is.
func _make_identity() -> Node:
	var identity_layer := DotPlatformIdentity.new()
	identity_layer.avatar_schema = WoAvatars.schema()
	identity_layer.stock_avatar_fn = WoAvatars.stock_avatar
	identity_layer.avatar_translate_fn = WoAvatars.from_site
	return identity_layer


func _game_load() -> DotResult:
	var world := game as WoGame

	if world == null:
		return DotResult.fail(DotError.CODE_STATE, "The registered game is not an WoGame.")

	add_command("wo_status", _cmd_status, "Show the round, the course and who is where")
	add_command("wo_net", _cmd_net, "Show what the netcode is doing")
	add_command("wo_courses", _cmd_courses, "List the courses and arenas, and any refused file")
	add_command("wo_reload", _cmd_reload, "Read the course directory again (next round)")
	add_command("wo_say", _cmd_say, "Say something to everybody, as the server")

	_wire_chat()
	_wire_identity()
	_wire_armed(world)
	_wire_map(world)
	_wire_progress(world)
	_add_tunables(world)

	_bots = add_cvar(
		"wo_bots", "1",
		"Keep the round full with stand-ins. 0 leaves the server as empty as it is."
	)

	# [b]Started here and not in the world's own `_ready`.[/b] `start()` lays the field out
	# and puts everybody on it, and a world that did that before the bridge existed would
	# have built a dozen platforms with nothing listening to `world_rebuilt` — a field the
	# server knows about and no client is ever told about. They would be invisible floors:
	# a player stands on nothing and the server says they are fine.
	_add_delivered_courses(world)
	world.start()

	log_info("the course is up", world.describe())
	return DotResult.success(null)


## Who somebody is reaches the world: a face as they are seated, and the real name and
## face once dot-platform has them.
##
## [b]Three events and one path.[/b] Admission finishes AFTER a player is seated — dot-server
## has no stage between authentication and content to hold them in — so the name and face
## a player is seated with are a guest's whenever the profile store is slower than the
## join; `player_admitted` is the moment the real ones exist. A wardrobe change and an
## operator's `platform_name` are the same thing later. All three end in
## [method WoNetBridge.refresh_player], a JOIN everybody already knows how to apply.
## The courses delivered beside this game: every server-only pack its descriptor names, read
## for a `courses/` directory where it is mounted.
##
## [b]Server-only, because a client never needs a course file.[/b] The server sends the course
## it is playing in STAGE, so the documents are `server_dependencies` in `game.yml` —
## mounted on this machine by dot-server's game manager and never put in a client's content
## sync. Duck-typed through the manager, because a dot-server from before the field has no
## `current_server_dependencies`, and on one of those this game plays its built-in course.
func _add_delivered_courses(world: WoGame) -> void:
	if server == null or world.catalogue == null:
		return

	var games: Object = server.get("games")

	if games == null or not games.has_method("current_server_dependencies"):
		return

	for key: String in games.call("current_server_dependencies"):
		var parts := DotGameDescriptor.split_key(key)
		var root := DotCloudClient.mount_prefix_for(StringName(parts[0]), parts[1]).path_join("courses")
		var _read := world.catalogue.add_directory(root)


func _wire_identity() -> void:
	var link := bridge as WoNetBridge

	if link == null:
		return

	link.avatar_fn = _avatar_for
	hook_post("player_admitted", _on_profile)
	hook_post("player_avatar_changed", _on_profile)
	hook_post("player_renamed", _on_profile)


## What a session looks like: what dot-platform resolved for them, or the stock person.
##
## [b]Through the platform module's `player_for`, and never the hub by a key made here.[/b]
## The hub keys a player by their scoped profile key, which only admission knows; a lookup
## by `u<session>` finds nobody, every time, and falls through to stock — which reads as
## "this player has no avatar" rather than as a wrong key. Duck-typed, because a server
## without dot-platform is a configuration.
func _avatar_for(session_id: int) -> DotAvatar:
	var session := server.session_by_userid(session_id) if server != null else null
	var platform: Object = server.modules.get_module("platform") \
		if server != null and server.modules != null else null

	if session != null and platform != null and platform.has_method("player_for"):
		var player: Variant = platform.call("player_for", session)

		if player is Object and (player as Object).get("avatar") is DotAvatar:
			return (player as Object).get("avatar") as DotAvatar

	if identity != null and identity.has_method("avatar_for"):
		return identity.call("avatar_for", String(WoNetBridge.player_key(session_id)))

	return null


func _on_profile(event: DotEvent) -> void:
	var session_id := event.get_int("userid")
	var session := server.session_by_userid(session_id) if server != null else null
	var link := bridge as WoNetBridge

	if session == null or link == null:
		return

	link.refresh_player(session_id, session.display_name, _avatar_for(session_id))


## The numbers an operator is actually going to want to change, as cvars.
##
## [b]Live, and each one writes through to the configuration the world already reads.[/b]
## The alternative is what most of this family's games still do — a JSON file and a restart
## — and the reason to do better here is the shape of this game: the whole thing is a
## balance between how fast the cannon fires, how stiff the platforms are and how long a
## round lasts, and an operator finds their server's numbers by moving one of them between
## rounds with people watching.
##
## [b]What is NOT here is anything the world has already built.[/b] `wo_columns` changes how
## many platforms the NEXT round is laid out with; it does not put a platform in the air
## now. A cvar that pretended otherwise would be one an admin sets in the middle of a round
## and then reports as broken.
func _add_tunables(world: WoGame) -> void:
	var config := world.config

	_tunable("wo_course_seconds", config.course_seconds,
		"The most seconds a course stays open (a course may ask for less)",
		func(value: float) -> void: config.course_seconds = clampf(value, 10.0, 1200.0))
	_tunable("wo_finale_seconds", config.finale_seconds,
		"Seconds a final death lasts before it is called on the clock",
		func(value: float) -> void: config.finale_seconds = clampf(value, 10.0, 900.0))
	_tunable("wo_countdown_seconds", config.countdown_seconds,
		"Seconds behind the start gate",
		func(value: float) -> void: config.countdown_seconds = clampf(value, 0.0, 30.0))
	_tunable("wo_teams", float(config.team_count), "Sides: 0 is everybody for themselves, or two to six teams",
		func(value: float) -> void:
			var teams := clampi(int(value), 0, 6)
			config.team_count = 0 if teams == 1 else teams)
	_tunable("wo_props_per_side", float(config.finale_props_per_side),
		"Props dropped into a final death, per side that made it",
		func(value: float) -> void: config.finale_props_per_side = clampi(int(value), 0, 40))
	_tunable("wo_weapons_per_side", float(config.finale_weapons_per_side),
		"Weapons laid out in a final death, per side that made it",
		func(value: float) -> void: config.finale_weapons_per_side = clampi(int(value), 0, 20))
	_tunable("wo_knock_min", config.knock_min_speed, "The least an obstacle throws a player, m/s",
		func(value: float) -> void: config.knock_min_speed = clampf(value, 0.0, config.knock_max_speed))
	_tunable("wo_progress_decides", 1.0 if config.progress_decides else 0.0,
		"Whether whoever got furthest wins a round nobody finished",
		func(value: float) -> void: config.progress_decides = value > 0.5)
	_tunable("wo_bot_spread", config.bot_aim_spread_degrees,
		"How far a stand-in's aim is off, in degrees, per bot per round",
		func(value: float) -> void: config.bot_aim_spread_degrees = clampf(value, 0.0, 45.0))
	_tunable("wo_bot_fumble", config.bot_fumble_chance,
		"Chance in a hundred a stand-in misses a jump",
		func(value: float) -> void: config.bot_fumble_chance = clampf(value, 0.0, 100.0))
	_tunable("wo_gravity", config.gravity, "Metres per second squared, for everything",
		func(value: float) -> void: config.gravity = value)
	_tunable("wo_spectate_camera", float(config.spectate_camera),
		"Who somebody who is out may watch: 0 anybody, 1 their own side, 2 nobody",
		func(value: float) -> void:
			config.spectate_camera = clampi(int(value), 0, 2)
			if world.spectate != null:
				world.spectate.set_force_camera(config.spectate_camera))
	_tunable("wo_min_players", float(config.minimum_players),
		"How many players the server keeps in a round with stand-ins",
		func(value: float) -> void: config.minimum_players = clampi(int(value), 0, 24))


## A number as an operator would type it: `34`, not `34.000000`.
##
## [b]Not `%g`, which GDScript's format strings do not have.[/b] It is accepted by the parser
## and fails at RUNTIME with "unsupported format character" — inside `_game_load`, which is
## the one place in the module sequence that unwinds everything above it. The symptom in
## game-buses-from-hell was a server whose netcode came up, logged that it was ready, and
## then reported that the game would not load.
static func _number(value: float) -> String:
	return "%d" % int(round(value)) if is_equal_approx(value, round(value)) else "%.3f" % value


## One cvar, its default taken from the configuration rather than written twice.
##
## [b]The default is the value the world was built with, and that is the whole point.[/b] A
## cvar declared with a literal default is a second copy of a number that
## `defaults < JSON < environment < argv` has already decided — so an operator who set
## `WO_COURSE_SECONDS=240` would see `wo_survival_seconds` report 120 and, worse, would
## reset their own setting the moment anything wrote the value back.
func _tunable(
	cvar_name: String, current: float, description: String, apply: Callable
) -> void:
	var cvar := add_cvar(cvar_name, _number(current), description)

	if cvar == null:
		return

	cvar.changed.connect(func(_old: String, _new: String) -> void:
		apply.call(cvar.get_float())
		log_info("a tunable changed", {"cvar": cvar_name, "now": cvar.get_string()})
	)


## [b]Nothing to undo.[/b] The commands are the module's own and [DotModule] removes them;
## the netcode, the bridge and the roster are [DotGameModule]'s and it tears them down in
## the reverse order it built them. The world is NOT this module's to free: it was in the
## tree before the module loaded, and a server can unload and reload a game module without
## the map going away, which is what `module reload` is for.
func _game_unload() -> void:
	_bot_ids.clear()


## Keeps enough people in the round for there to be one.
##
## [b]Two sides with somebody on each, or nothing happens at all.[/b] An elimination round
## ends the moment a side has nobody alive, and a side with nobody AT ALL satisfies that on
## the first tick — so a server with one person on it would start a round, end it, start
## another and end that, several times a second, for as long as nobody else joined. Every
## one of those rounds is decided correctly, which is why nothing errors.
##
## A stand-in is removed the moment a person takes their place. They are here to make the
## game exist, not to take the fun half from the people who came to play it.
func _game_tick(_tick: int, delta: float) -> void:
	_since_roster_check += delta

	if _since_roster_check < ROSTER_INTERVAL:
		return

	_since_roster_check = 0.0
	_keep_the_round_full()
	_note_pings()


## Each session's ping onto its player, for the Tab board. dot-server already keeps it.
func _note_pings() -> void:
	var world := game as WoGame
	if world == null or server == null:
		return
	for session in server.playing_sessions():
		var who: WoPlayer = world.players.get(WoNetBridge.player_key(session.userid))
		if who != null:
			who.ping_ms = session.ping_ms


func _keep_the_round_full() -> void:
	var world := game as WoGame

	if world == null or bridge == null or _bots == null or not _bots.get_bool():
		return

	var wanted := world.config.minimum_players
	var humans := 0

	for id: StringName in world.players:
		if not (world.players[id] as WoPlayer).is_bot:
			humans += 1

	# Forget any that have gone for some other reason — a round reset, an admin — so the
	# count below is of stand-ins that actually exist.
	for index in range(_bot_ids.size() - 1, -1, -1):
		if not world.players.has(_bot_ids[index]):
			_bot_ids.remove_at(index)

	var short := wanted - humans - _bot_ids.size()

	for _i in range(maxi(short, 0)):
		var bot: WoPlayer = bridge.call("add_bot", _bot_name())

		if bot == null:
			break

		_bot_ids.append(bot.player_id)

	for _i in range(maxi(humans + _bot_ids.size() - wanted, 0)):
		if _bot_ids.is_empty():
			break

		var leaving: StringName = _bot_ids.pop_back()
		bridge.call("remove_player", WoNetBridge.session_of(leaving))


## Names for the stand-ins, so a scoreboard of four of them is readable.
static func _bot_name() -> String:
	var names := PackedStringArray([
		"Splash", "Tumble", "Wobble", "Dunk", "Belly Flop", "Soggy", "Bounce", "Skid",
	])
	return String(names[randi() % names.size()])


## Joins the bridge's chat seam to the services layer's router.
##
## [b]Here rather than in either of them, because this is the only object that holds
## both.[/b] The bridge knows what arrived on the wire and nothing about what a line means;
## the services layer knows the rules and nothing about the wire. That separation is why a
## client cannot send a line with somebody else's name on it: what crosses is a channel id
## and a string, and everything else is decided on this side.
func _wire_chat() -> void:
	if bridge == null or services == null:
		return

	bridge.connect("say_requested", _on_say_requested)
	services.connect("command_entered", _on_chat_command)


## A round's layout is what a server listing prints as the map.
##
## The layout is this game's map: the field the round is played on, picked per round. Said
## on every round rather than once, because dot-server forgets the map whenever a game
## unloads and a layout changes between rounds.
## The map a server browser shows is the stage: the course, and the arena while a final
## death is on. Reported on every rebuild, because the server forgets it whenever a game
## unloads and a browser showing last round's course is a browser lying.
func _wire_map(world: WoGame) -> void:
	if world.stage != null and not world.stage.doc.is_empty():
		report_map(String(world.stage.id()))

	world.world_rebuilt.connect(func() -> void:
		report_map(String(world.stage.id()))
	)


## And the one game event the bridge cannot see for itself.
##
## `_arm` happens inside the world and the bridge is not listening to the world's weapons,
## because a weapon is not a replicated entity here — it is a fact about a player that a
## watcher's HUD wants to name. One signal is cheaper than a behaviour.
func _wire_armed(world: WoGame) -> void:
	if bridge == null:
		return

	world.player_armed.connect(func(player_id: StringName, weapon_id: StringName) -> void:
		bridge.call("announce_armed", player_id, weapon_id)
	)


## An achievement is told to the one person who earned it.
##
## [b]As a notice, which a client already draws in its chat box[/b], rather than a new event
## kind: an unlock is text for one player, which is exactly what a notice is — and a stand-in
## never earns one, because [WoProgress] does not count them.
func _wire_progress(world: WoGame) -> void:
	if bridge == null:
		return

	# What a player keeps is filed under their scoped profile key, so it outlives the
	# connection; see [WoProgress]. Nothing for a stand-in or a guest, who keep their seat's.
	if world.progress != null:
		world.progress.durable_key_fn = func(id: StringName) -> String:
			var session := server.session_by_userid(WoNetBridge.session_of(id)) \
				if server != null else null
			var platform: Object = server.modules.get_module("platform") \
				if server != null and server.modules != null else null

			if session == null or platform == null or not platform.has_method("player_for"):
				return ""

			var held: Variant = platform.call("player_for", session)
			return str((held as Object).call("key")) if held is Object else ""

	world.achievement_earned.connect(func(id: StringName, title: String, points: int) -> void:
		var peer_id: int = bridge.call("peer_for_player", WoNetBridge.session_of(id))

		if peer_id > 0:
			bridge.call("notice", peer_id, "Achievement: %s (+%d)" % [title, points])
	)


func _on_say_requested(peer_id: int, channel_id: StringName, text: String) -> void:
	var said: DotResult = services.call("say", peer_id, channel_id, text)

	if said.ok:
		return

	# Back to the one person who asked. A refusal broadcast would be a rate limit announced
	# to the server.
	bridge.call("notice", peer_id, said.error.message)


## A `!command` typed into chat. Run through the console as the person who typed it.
##
## [b]As THEM, not as the server.[/b] `run_command_as_uid` builds a context with that
## player's own flags, so `!kick` from somebody without the flag is refused by the same file
## that refuses it at the console — rather than by this function having an opinion.
func _on_chat_command(peer_id: int, command: String, args: PackedStringArray) -> void:
	if server == null:
		return

	var session := server.session_of(peer_id)

	if session == null:
		return

	for reply in server.run_command_as_uid(
		session.uid(), command, args, DotCmdContext.Source.CHAT
	):
		bridge.call("notice", peer_id, reply)


func _cmd_say(ctx: DotCmdContext) -> void:
	var text := ctx.rest()

	if text.strip_edges() == "":
		ctx.reply("Say what?")
		return

	if services == null or services.get("chat") == null:
		ctx.reply("This server has no chat.")
		return

	var announced: Variant = services.get("chat").call("announce", text, WoServices.CH_ALL)

	if announced is DotResult and not (announced as DotResult).ok:
		ctx.reply_error(announced)
		return

	ctx.reply("Said: %s" % text)


func _cmd_status(ctx: DotCmdContext) -> void:
	var world := game as WoGame

	if world == null:
		ctx.reply("No world.")
		return

	ctx.reply_lines(world.describe_lines())


func _cmd_net(ctx: DotCmdContext) -> void:
	if bridge == null:
		ctx.reply("No bridge; this server is not replicating anything.")
		return

	ctx.reply_lines(bridge.call("describe_lines"))

	if services != null:
		ctx.reply_lines(services.call("describe_lines"))


func _cmd_courses(ctx: DotCmdContext) -> void:
	var world := game as WoGame

	if world == null or world.catalogue == null:
		ctx.reply("No world.")
		return

	ctx.reply_lines(world.catalogue.describe_lines())
	ctx.reply("playing: %s" % str(world.course_doc.get("id", "-")))


func _cmd_reload(ctx: DotCmdContext) -> void:
	var world := game as WoGame

	if world == null or world.catalogue == null:
		ctx.reply("No world.")
		return

	var loaded := world.catalogue.load_from(world.config.course_directory)
	ctx.reply("%d documents read; %d refused. The next round draws from them." % [
		loaded, world.catalogue.refused.size()])


func describe() -> Dictionary:
	var out := super.describe()
	var world := game as WoGame

	if world != null:
		out.merge({"round": world.round_number, "world": world.describe()}, true)

	return out
