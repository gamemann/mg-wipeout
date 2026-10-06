extends Node3D

const WoCatalogue := preload("wo_catalogue.gd")
const WoConfig := preload("wo_config.gd")
const WoContent := preload("wo_content.gd")
const WoCourse := preload("wo_course.gd")
const WoCourseDoc := preload("wo_course_doc.gd")
const WoPlayer := preload("wo_player.gd")
const WoProgress := preload("wo_progress.gd")
const WoRules := preload("wo_rules.gd")
const WoSpectate := preload("wo_spectate.gd")

## The simulation. Headless, authoritative, and the only thing that decides anything.
##
## [b]A round is a course and, sometimes, a fight.[/b] Everybody runs the same course from
## the same start. Falling in costs time — you are put back at the last checkpoint you
## crossed — and never the round. When everybody is across, or the clock runs out, the round
## is decided by who finished: nobody (whoever got furthest wins), one side (it wins), or two
## or more — and then everybody who finished is thrown into an arena they have never seen,
## with props to pick up and throw and weapons lying about, for a last-side-standing final
## death. Everybody who did not finish watches it from the gallery.
##
## [b]What it owns and what it borrows.[/b] The round, the sides and the scoreboard are
## dot-match's (decided through [WoRules]); health and damage are dot-combat's; the props
## and the hand that carries them are dot-props'; the weapons are zee-dot-weapons'. The
## course and everything on it are [WoCourse], and are this game's own.

const CHANNEL := "wo.game"

## Where this world publishes itself, so a module can find it. A registry name and not an
## autoload: a server and a client in one process are two of these.
const SERVICE := &"wo_game"

## Snapshots a second. Thirty, like mg-smash-copter: what a player reads continuously here is
## other people on moving ground, and at twenty a rider on a turntable steps.
const NET_SNAPSHOT_RATE := 30

## How far a position may be from the origin, in metres, on the wire.
##
## [b]Five hundred and twelve, against mg-smash-copter's two hundred and fifty-six,[/b] because
## a course is long: the longest in mg-wipeout-maps runs two hundred metres from the start.
## Both ends read it from here; game-arena once had two numbers in two files and drew sky in
## every direction.
const NET_WORLD_EXTENT := 512.0

const TEAM_COLOURS: Array[Color] = [
	Color(0.85, 0.27, 0.26),
	Color(0.29, 0.53, 0.86),
	Color(0.35, 0.72, 0.38),
	Color(0.92, 0.78, 0.22),
	Color(0.66, 0.42, 0.82),
	Color(0.91, 0.55, 0.20),
]

const TEAM_NAMES: Array[String] = [
	"Red", "Blue", "Green", "Yellow", "Violet", "Orange",
]

## Where the first solo side starts. A side id above any team id, so "is this a team" is a
## comparison and a solo side can never be mistaken for red.
const SOLO_SIDE_BASE := 100

## Which part of the round it is.
enum Phase {
	## Between rounds, or waiting for enough people to start one.
	IDLE,
	## Everybody on the start pad behind the gate.
	COUNTDOWN,
	## The gate is down and the course is open.
	COURSE,
	## The finishers are in the arena, unhurtable, while the props land.
	HANDOVER,
	## The final death.
	FINALE,
}

const DIED_SHOT := &"shot"
const DIED_THROWN := &"thrown"
const DIED_FELL := &"fell"
const DIED_BLAST := &"blast"
## Knocked out on the course by an obstacle, or by lightning.
const DIED_KNOCKED := &"knocked"
const DIED_STRUCK := &"struck"

## Metres within which a player standing over a weapon picks it up.
const PICKUP_REACH := 1.3

## How far a prop may be from somebody's eyes to be picked up, in metres.
const GRAB_REACH := 3.5

## Seconds a thrown prop is "thrown" — dangerous, and credited to whoever threw it.
const THROWN_SECONDS := 3.0

signal player_added(player_id: StringName)
signal player_removed(player_id: StringName)

## A round began, on [param course_id].
signal round_began(number: int, course_id: StringName)

## The stage is about to be taken down and rebuilt. Before, for the bridge's sake.
signal world_clearing()

## The stage has just been rebuilt: a course at the top of a round, an arena at a handover.
signal world_rebuilt()

## A round ended. [param winner] is a side (0 for a draw); [param winner_name] says who.
signal round_over(number: int, winner: int, winner_name: String)

signal phase_changed(phase: int)

signal player_died(player_id: StringName, by: StringName, why: StringName)

## Somebody fell in and was put back. Not a death: the course goes on.
signal player_fell(player_id: StringName, checkpoint: int)

signal checkpoint_reached(player_id: StringName, index: int)

## Somebody crossed the finish, [param place] first, in [param seconds].
signal player_finished(player_id: StringName, place: int, seconds: float)

signal achievement_earned(player_id: StringName, title: String, points: int)

## Somebody was handed, or picked up, a weapon.
signal player_armed(player_id: StringName, weapon_id: StringName)

## A weapon was laid out in the arena, or picked up off the floor.
signal pickup_placed(pickup_id: int, weapon_id: StringName, at: Vector3)
signal pickup_taken(pickup_id: int, by: StringName)

signal blast(at: Vector3, radius: float)

@export var config: WoConfig = null

## Whether this instance decides anything. A client sets this false.
@export var authoritative: bool = true

@export_range(1, 240, 1) var tick_rate: int = 64

## Whether something else drives the tick: the bridge, on both ends. See mg-smash-copter.
@export var external_tick: bool = false

## Whether this world publishes itself under [constant SERVICE].
@export var register_service: bool = true

## Whether the stage draws its sky and water. A client sets it.
@export var draw_world: bool = false

## The course, or during a final death the arena. One node, rebuilt. See [method _begin_handover].
var stage: WoCourse = null

var catalogue: WoCatalogue = null
var props: DotPropSpawner = null
var prop_damage: DotPropDamage = null
var combat: DotCombatManager = null
var match_node: DotMatch = null
var random: DotRandomManager = null
var physics: DotPhysicsLayout = null
var effects: DotFxManager = null
var spectate: WoSpectate = null
var progress: WoProgress = null

## player id -> WoPlayer.
var players: Dictionary = {}

## player id -> side. A team id with teams, a side of one's own (100+) without.
var sides: Dictionary = {}

var round_number: int = 0

## Seconds into the current phase. Simulated, never a wall clock.
var phase_elapsed: float = 0.0

## Seconds into the course, from the gate dropping. What a finish time is.
var course_elapsed: float = 0.0

var phase: int = Phase.IDLE

## The course this round is being run on, and the arena if the round reached one.
var course_doc: Dictionary = {}
var arena_doc: Dictionary = {}

var entities := DotEntityTable.new()

## What the server last said about numbers a client cannot count. Negative is "count it".
var remote_finished: int = -1
var remote_alive: int = -1
var remote_playable: bool = false

## The pickups lying in an arena: id -> {weapon, at}.
var pickups: Dictionary = {}

var _tick: int = 0
var _round_seed: int = 0
var _finish_count: int = 0
var _next_solo_side: int = SOLO_SIDE_BASE
var _next_pickup: int = 1

## Whether the course standing now has not been raced yet: the warmup's, until round one.
var _course_unplayed: bool = false

## Whether the round has been decided, and who won. What [WoRules] reads.
var _decided: bool = false
var _winner: int = 0
var _winner_name: String = ""

## prop instance id -> {by, until}: who threw it and when it stops being dangerous.
var _thrown: Dictionary = {}

## player id -> the last tick a thrown prop hurt them, so one prop is one hit.
var _thrown_hit: Dictionary = {}

## Bots: player id -> the route point they are heading for, and their aim error.
var _bot_route: Dictionary = {}
var _bot_hands: Dictionary = {}
var _bot_wait: Dictionary = {}

## Bots: player id -> ticks spent getting up to speed on a top before jumping off it.
var _bot_runup: Dictionary = {}

## Bots: player id -> `[position, tick]` a second ago, for [method _bot_unstick].
var _bot_stuck: Dictionary = {}


func _ready() -> void:
	if config == null:
		config = WoConfig.new()

	var valid := config.validate()

	if not valid.ok:
		# FATAL is reserved for "the process cannot continue", and a configuration that
		# contradicts itself is not that: say so loudly and refuse to run a round.
		DotLog.error(CHANNEL, "the configuration is not usable", {"why": valid.error.message})
		return

	_round_seed = config.seed_value

	_build_physics()
	_apply_gravity()
	_build_random()
	_build_stage()
	_build_props()
	_build_combat()
	_build_effects()
	_build_match()
	_build_spectate()
	_build_progress()

	if authoritative:
		catalogue = WoCatalogue.new()
		var _loaded := catalogue.load_from(config.course_directory)
		# Laid out now, not on the first round: dot-match runs a warmup first, and an empty
		# world through the warmup is indistinguishable from a map that failed to load.
		_lay_out_course()

	if register_service:
		DotRegistry.register(SERVICE, self)

	DotLog.info(CHANNEL, "world ready", config.describe())


func _exit_tree() -> void:
	if register_service:
		DotRegistry.unregister_instance(SERVICE, self)


# --- Building ---------------------------------------------------------------

## The named collision layers. Three kinds of thing here: the world, players and props.
func _build_physics() -> void:
	physics = DotPhysicsLayout.custom(&"wipeout", [&"world", &"player", &"prop"])

	for layer in physics.layers:
		match layer.id:
			&"player":
				# Not other players. A shove between two capsules on a narrow beam is a race
				# decided by who walked into whom, and it is not predictable: the other player
				# is drawn in the past on every client.
				layer.collides_with = [&"world", &"prop"]
			&"prop":
				layer.collides_with = [&"world", &"player", &"prop"]
			_:
				layer.collides_with = [&"player", &"prop"]

	var built := physics.build()

	if not built.ok:
		DotLog.error(CHANNEL, "the collision layout would not build", {"why": built.error.message})
		physics = null


## The gravity the course is tuned against, on this world's own physics SPACE. A project
## setting does not travel with a delivered pack; see [member WoConfig.gravity].
func _apply_gravity() -> void:
	var world := get_world_3d()

	if world == null:
		DotLog.warn(CHANNEL, "no world to set gravity on", {})
		return

	PhysicsServer3D.area_set_param(world.space, PhysicsServer3D.AREA_PARAM_GRAVITY, config.gravity)


func _build_random() -> void:
	random = DotRandomManager.new()
	random.name = "Random"
	# Off: a registry name is process-wide, and two worlds in one process is every suite.
	random.register_as_service = false
	add_child(random)
	var _started := random.setup()
	random.reseed(_round_seed)


func _build_stage() -> void:
	stage = WoCourse.new()
	stage.name = "Stage"
	stage.physics = physics
	stage.tick_rate = tick_rate
	stage.draw_world = draw_world
	add_child(stage)


func _build_props() -> void:
	props = DotPropSpawner.new()
	props.name = "Props"
	props.catalogue = WoContent.props(config)
	props.limits = DotPropLimits.new()
	# The world puts these out, not a player: the per-player budget and cooldown are the wrong
	# shape, and the world cap has to be above what an arena asks for or the last few silently
	# never appear.
	props.limits.spawn_interval = 0.0
	props.limits.per_player_budget = config.prop_budget + 10
	props.limits.world_budget = config.prop_budget + 10
	props.limits.clean_up_on_leave = false
	props.authoritative = authoritative
	add_child(props)

	prop_damage = DotPropDamage.new()
	prop_damage.name = "PropDamage"
	prop_damage.authoritative = authoritative
	props.add_child(prop_damage)
	prop_damage.exploded.connect(_on_prop_exploded)

	props.removed.connect(func(prop: DotPropInstance, _reason: StringName) -> void:
		_thrown.erase(prop.instance_id)
	)


func _build_combat() -> void:
	combat = DotCombatManager.new()
	combat.name = "Combat"
	combat.is_authority = authoritative
	combat.register_service = false

	var rules := DotDamageRules.new()
	rules.friendly_fire = false
	rules.self_damage = true
	rules.hit_groups = true
	combat.rules = rules

	# Lag compensation OFF here and turned on by the bridge with the callables that make it
	# real — mg-smash-copter's finding: left on, a delivered server logged "no rewind
	# function" at every boot about a server where it works.
	var settings := DotCombatConfig.new()
	settings.lag_compensation = false
	combat.config = settings

	# A trace, or every shot goes through the arena's walls. Before `setup`, which warns.
	var trace := DotTracePhysics.for_world(get_world_3d())

	if physics != null:
		trace.collision_mask = physics.layer_mask(&"world")

	combat.trace = trace

	# Which side an entity is on, or friendly fire is ON in a team game whose rules say off —
	# and in a solo game every player is their own side, so `team_of` answering 0 for all of
	# them would make everybody everybody's team mate and nobody could hurt anybody.
	combat.resolver = DotDamageResolver.with_rules(rules)
	combat.resolver.hit_groups = DotHitGroup.defaults()
	combat.resolver.team_of = func(entity_id: int) -> int:
		return team_of(entities.key_for_id(entity_id))

	# `add_child` IS the setup; calling it again doubled every boot line. See mg-smash-copter.
	add_child(combat)


## A shake for a knock and a flash for the gate, and nothing else. Client side.
func _build_effects() -> void:
	if authoritative:
		return

	var catalogue_fx := DotFxCatalogue.new()

	var knock := DotFxDef.new()
	knock.id = &"knock"
	knock.kind = DotFxDef.Kind.SHAKE
	knock.shake_trauma = 0.45
	knock.max_distance = 12.0
	catalogue_fx.add(knock)

	var go := DotFxDef.new()
	go.id = &"go"
	go.kind = DotFxDef.Kind.SCREEN
	go.flash_peak = 0.22
	go.flash_colour = Color(0.98, 0.86, 0.35, 1.0)
	go.flash_decay_ms = 380
	catalogue_fx.add(go)

	effects = DotFxManager.new()
	effects.name = "Effects"
	effects.catalogue = catalogue_fx
	effects.config = DotFxConfig.new()
	effects.register_as_service = false
	add_child(effects)

	DotLog.result(CHANNEL, "the effects layer", effects.setup())


func _build_match() -> void:
	match_node = DotMatch.new()
	match_node.name = "Match"
	match_node.register_service = false

	var match_config := DotMatchConfig.new()
	match_config.tick_rate = tick_rate
	match_config.auto_start = false
	match_config.log_transitions = false
	match_node.config = match_config

	var rules: DotMatchRules = WoRules.make()
	rules.intermission_sec = config.intermission_seconds
	rules.warmup_sec = config.warmup_seconds
	rules.countdown_sec = 0.0
	rules.team_based = config.teams()
	# Two: one person alone on a course has nobody to beat and no final death to reach, and a
	# server holding one person would start a round, decide it and start another. The bots
	# (`minimum_players`) are what makes an empty server playable.
	rules.min_players = 2
	rules.set(&"decision_fn", _decision)
	rules.time_limit_sec = config.countdown_seconds + config.course_seconds \
		+ config.handover_seconds + config.finale_seconds + 60.0
	match_node.rules = rules

	# Scoped to the match node, which finds nothing: this game places its own players, and an
	# unset `spawns_ref` walks the whole scene and finds another world's. See mg-smash-copter.
	match_node.spawns_ref = DotNodeRef.of_path(^".")

	add_child(match_node)

	match_node.round_started.connect(_on_round_started)
	match_node.round_ended.connect(_on_round_ended)

	var teams: Array[DotTeam] = []

	for index in range(config.team_count if config.teams() else 0):
		teams.append(DotTeam.make(index + 1, TEAM_NAMES[index], TEAM_COLOURS[index]))

	match_node.teams.teams = teams
	match_node.teams.force_balance = config.autobalance
	match_node.teams.allow_choice = config.allow_team_choice
	# Off: `sides` decides a team and dot-match is told. Its default of 1 refused joins and
	# left stand-ins on no team in two games before this one.
	match_node.teams.max_difference = 0
	match_node.teams.reindex()


func _decision() -> Dictionary:
	return {"decided": _decided, "winner": _winner}


func _build_spectate() -> void:
	spectate = WoSpectate.new()
	spectate.name = "Spectate"
	spectate.players = players
	spectate.sides = sides
	spectate.phase_fn = func() -> int: return phase
	spectate.in_showdown_fn = func(p: int) -> bool:
		return p == Phase.HANDOVER or p == Phase.FINALE
	add_child(spectate)

	var ready_now := spectate.setup(authoritative, tick_rate, config.spectate_camera)

	if not ready_now.ok:
		DotLog.warn(CHANNEL, "spectating is off", {"why": ready_now.error.message})
		remove_child(spectate)
		spectate.queue_free()
		spectate = null


func _build_progress() -> void:
	if not authoritative or not config.keep_progress:
		return

	progress = WoProgress.new()
	progress.name = "Progress"
	progress.players = players
	progress.sides = sides
	add_child(progress)

	var ready_now := progress.setup(config.progress_directory, config.report_progress)

	if not ready_now.ok:
		DotLog.warn(CHANNEL, "progress is off", {"why": ready_now.error.message})
		remove_child(progress)
		progress.queue_free()
		progress = null
		return

	progress.earned.connect(func(id: StringName, title: String, points: int) -> void:
		achievement_earned.emit(id, title, points)
	)


func _refresh_overviews() -> void:
	if spectate == null or stage == null:
		return

	var box := stage.bounds()
	var centre := box.get_center()
	var reach := maxf(box.size.length() * 0.5, 12.0)
	var eye := centre + Vector3(reach * 0.6, reach * 0.55 + 10.0, reach * 0.6)
	var view := Transform3D(Basis.IDENTITY, eye).looking_at(centre, Vector3.UP)
	spectate.set_overviews(view, view)


# --- Players ----------------------------------------------------------------

## Puts somebody in the world. [param wanted_team] is a team id, or 0 to be placed.
func add_player(
	player_id: StringName,
	display_name: String,
	wanted_team: int = 0,
	samples_input: bool = false
) -> WoPlayer:
	if players.has(player_id):
		return players[player_id]

	var side := _side_for_new_player(wanted_team)

	var player := WoPlayer.new()
	player.name = "Player_%s" % String(player_id)
	player.player_id = player_id
	player.display_name = display_name
	player.samples_input = samples_input
	player.tick_rate = tick_rate
	player.config = config
	player.stage = stage
	player.team = side
	add_child(player)

	if physics != null:
		var applied := physics.apply_to(player, &"player")

		if not applied.ok:
			DotLog.warn(CHANNEL, "a player could not be put on its collision layer", {
				"why": applied.error.message,
			})

		# And the motor's own mask, which defaults to 1. A controller left on the default
		# sweeps against layer one only, which is a player falling through the course.
		player.controller.tunables.collision_mask = physics.collision_mask(&"player")

	var opened := entities.open(
		DotEntity.KIND_PLAYER, player, &"", player_id, float(_tick) / float(maxi(tick_rate, 1))
	)

	if not opened.ok:
		DotLog.error(CHANNEL, "could not open an entity for a player", {
			"id": String(player_id), "why": opened.error.message,
		})

	player.entity_id = (opened.value as DotEntityHandle).id if opened.ok else 0

	var health := DotHealth.new()
	health.name = "Health"
	health.max_health = config.player_health
	health.health = config.player_health
	player.add_child(health)
	player.health = health

	if combat != null:
		combat.register_health(player.entity_id, health)
		_give_hitboxes(player)

	health.died.connect(func(damage: DotDamage) -> void: _on_player_died(player, damage))

	players[player_id] = player
	sides[player_id] = side

	if match_node != null:
		var seated := match_node.add_player(
			String(player_id), display_name, _tick, side if config.teams() else 0
		)

		if not seated.ok:
			DotLog.error(CHANNEL, "dot-match refused a player", {
				"id": String(player_id), "side": side, "why": seated.error.message,
			})

	# Placed NOW, not only at the top of a round: a joiner left at the origin is a joiner in
	# the water, and mg-smash-copter's version of that ended rounds.
	place_one(player)

	DotLog.debug(CHANNEL, "player joined", {"id": String(player_id), "side": side})

	# Last, after the health and the side: the bridge answers this by replicating the player.
	player_added.emit(player_id)
	return player


## Somewhere on a player a shot can land. Without it nobody can be shot and nothing says so.
func _give_hitboxes(player: WoPlayer) -> void:
	var boxes := DotHitboxSet.new()
	boxes.name = "Hitboxes"
	boxes.owner_ref = DotNodeRef.of_path(^"..")
	player.add_child(boxes)

	var body := DotHitbox.new()
	body.name = "Chest"
	body.group = DotHitGroup.CHEST
	body.shape = DotHitbox.Shape.CAPSULE
	body.radius = 0.34
	body.height = 1.25
	body.position = Vector3(0.0, 0.78, 0.0)
	body.damage_scale = 1.0
	body.precedence = 0
	boxes.add_child(body)

	var head := DotHitbox.new()
	head.name = "Head"
	head.group = DotHitGroup.HEAD
	head.shape = DotHitbox.Shape.SPHERE
	head.radius = 0.19
	head.position = Vector3(0.0, WoPlayer.EYE_HEIGHT + 0.06, 0.0)
	head.damage_scale = 2.2
	head.precedence = 10
	boxes.add_child(head)

	boxes.refresh()
	boxes.register_with(combat, player.entity_id)


## Puts one player somewhere they can be, for the phase it is.
##
## A joiner in the middle of a course starts at the start, behind everybody, which is honest;
## a joiner during a final death they did not reach watches it from the gallery.
func place_one(player: WoPlayer) -> void:
	if stage == null or stage.doc.is_empty():
		return

	if stage.is_arena():
		player.watching = true
		var spot := stage.gallery_spot(players.size())
		player.place_at(spot[0], spot[1])
		return

	# Full rows, not centred on how many there are: a joiner's seat must not move the seats
	# of the people already standing there, or the second joiner lands on the first.
	var spot := stage.start_spot(players.size() - 1, 1000)
	player.place_at(spot[0], spot[1])

	if spectate != null:
		spectate.on_spawned(player.player_id)


## Which side somebody new goes on.
##
## With teams, the smallest one, ties to the lower id — explicitly, because a server and a
## client that disagree about somebody's side disagree about friendly fire. Without, a side
## of their own, numbered from [constant SOLO_SIDE_BASE] in join order.
func _side_for_new_player(wanted: int) -> int:
	if not config.teams():
		_next_solo_side += 1
		return _next_solo_side - 1

	if wanted >= 1 and wanted <= config.team_count:
		return wanted

	var counts: Array[int] = []
	counts.resize(config.team_count)
	counts.fill(0)

	for id: StringName in sides:
		var side := int(sides[id])

		if side >= 1 and side <= config.team_count:
			counts[side - 1] += 1

	var smallest := 0

	for index in range(config.team_count):
		if counts[index] < counts[smallest]:
			smallest = index

	return smallest + 1


func remove_player(player_id: StringName) -> void:
	if not players.has(player_id):
		return

	var player: WoPlayer = players[player_id]

	if player.grab != null:
		var _dropped := player.grab.drop()

	# Before the node goes: dot-combat keyed a health on this entity, and a stale record has
	# no symptom until the process runs out of memory.
	if combat != null and is_instance_valid(combat) and player.entity_id != 0:
		combat.forget(player.entity_id)
		var _closed := entities.close(player.entity_id, DotEntityTable.REASON_OWNER_LEFT)

	if match_node != null:
		match_node.remove_player(String(player_id))

	players.erase(player_id)
	sides.erase(player_id)
	_bot_route.erase(player_id)
	_bot_hands.erase(player_id)
	_bot_wait.erase(player_id)
	_bot_runup.erase(player_id)
	_bot_stuck.erase(player_id)
	player.queue_free()

	if spectate != null:
		spectate.on_left(player_id)

	if progress != null:
		progress.leave(player_id)

	player_removed.emit(player_id)


func team_of(player_id: StringName) -> int:
	return int(sides.get(player_id, 0))


## A side's name: a team's colour, or the one player on a solo side.
func side_name(side: int) -> String:
	if side >= 1 and side <= TEAM_NAMES.size() and config.teams():
		return TEAM_NAMES[side - 1]

	for id: StringName in sides:
		if int(sides[id]) == side and players.has(id):
			return (players[id] as WoPlayer).display_name

	return "nobody"


func side_colour(side: int) -> Color:
	if side >= 1 and side <= TEAM_COLOURS.size() and config.teams():
		return TEAM_COLOURS[side - 1]

	# A solo side's colour, from its number, so every client paints the same person the same.
	return Color.from_hsv(fposmod(float(side) * 0.137, 1.0), 0.55, 0.85)


func players_on(side: int) -> Array[WoPlayer]:
	var out: Array[WoPlayer] = []

	for id: StringName in players:
		if int(sides.get(id, 0)) == side:
			out.append(players[id])

	return out


## How many people are up and in the arena, or on the course.
func alive_count() -> int:
	if not authoritative and remote_alive >= 0:
		return remote_alive

	var total := 0

	for id: StringName in players:
		var player: WoPlayer = players[id]

		if player.is_alive() and not player.watching:
			total += 1

	return total


func finished_count() -> int:
	if not authoritative and remote_finished >= 0:
		return remote_finished

	return _finish_count


## Whether there are enough people for a round. Two, of anybody.
func sides_are_playable() -> bool:
	if not authoritative:
		return remote_playable

	return players.size() >= 2


# --- The round --------------------------------------------------------------

func start() -> void:
	if not authoritative:
		return

	# Built again here, not only in `_ready`: the world furnishes itself when it opens, but on
	# a server nothing is listening then — the module builds the bridge that answers
	# `world_rebuilt` — and a course built before it is a course no client is ever sent. A
	# player joining during the warmup would stand in an empty sky. The SAME course: the one
	# the warmup shows is the one the first round plays.
	#
	# Unless it is no longer one this server plays: on a delivered server the courses arrive
	# with the module, after the world opened on the only course it had then — the built-in
	# practice one, which drops out of the rotation once there is anything else.
	var id := StringName(str(course_doc.get("id", "")))

	if not course_doc.is_empty() and catalogue != null \
			and catalogue.playable_courses(config.course_ids).has(id):
		var _rebuilt := build_stage(course_doc)
		_place_on_start()
	else:
		_lay_out_course()

	match_node.start(_tick)


func _on_round_started(number: int) -> void:
	round_number = number
	_round_seed = config.seed_value + number * 7919
	random.reseed(_round_seed)

	# The course the warmup showed, for the first round; the next one after that. Drawing a new
	# course here every time put a player who had spent the warmup reading one course on a
	# different one the moment the round began.
	if _course_unplayed and not course_doc.is_empty():
		var _rebuilt := build_stage(course_doc)
		_place_on_start()
	else:
		_lay_out_course()

	_course_unplayed = false
	_decided = false
	_winner = 0
	_winner_name = ""
	_finish_count = 0

	if progress != null:
		progress.on_round_began()

	_set_phase(Phase.COUNTDOWN)
	round_began.emit(number, stage.id())

	DotLog.info(CHANNEL, "round began", {
		"number": number, "course": String(stage.id()), "seed": _round_seed,
		"players": players.size(),
	})


func _on_round_ended(number: int, winner: int, _outcome: int) -> void:
	_set_phase(Phase.IDLE)

	if progress != null:
		progress.on_round_over(winner)

	round_over.emit(number, winner, _winner_name)
	DotLog.info(CHANNEL, "round over", {"number": number, "winner": _winner_name})


## The next course, built, and everybody on its start pad.
func _lay_out_course() -> void:
	if catalogue == null:
		return

	var doc := catalogue.next_course(
		config.course_ids, config.shuffle_courses, random.stream(&"course"),
		StringName(str(course_doc.get("id", "")))
	)

	# The round's weather, drawn here and sent inside the document, so every machine reads
	# the same gusts and strikes and nothing more travels per tick.
	if authoritative and not doc.is_empty():
		doc = doc.duplicate(true)
		doc["weather"] = draw_weather(doc, random.stream(&"weather"), _tick)

	build_stage(doc)
	_place_on_start()
	_course_unplayed = true


## Gusts and lightning for one course, from the round's own stream. Ticks are game ticks
## from [param start]: the countdown and the whole course clock are covered.
func draw_weather(doc: Dictionary, rng: DotRandomStream, start: int) -> Dictionary:
	var out := {"gusts": [], "strikes": []}
	var rate := float(maxi(tick_rate, 1))
	var span := (config.countdown_seconds + course_limit_for(doc)) * rate

	if config.wind_strength > 0.0 and rng.next_unit() < config.wind_chance:
		for i in range(rng.next_range_i(2, 5)):
			var from := start + int(rng.next_range_f(config.countdown_seconds * rate, span * 0.9))
			var angle := rng.next_range_f(0.0, TAU)
			out["gusts"].append({
				"from": from, "to": from + int(rng.next_range_f(2.0, 6.0) * rate),
				"dx": cos(angle), "dz": sin(angle),
				"strength": rng.next_range_f(0.4, 1.0) * config.wind_strength,
			})

	if config.storm_strikes > 0 and rng.next_unit() < config.storm_chance:
		var route := _weather_route(doc)
		for i in range(config.storm_strikes):
			var spot: Vector3 = route[rng.next_range_i(0, route.size() - 1)] if not route.is_empty() else Vector3.ZERO
			out["strikes"].append({
				"tick": start + int(rng.next_range_f(config.countdown_seconds * rate, span * 0.95)),
				"x": spot.x + rng.next_range_f(-3.0, 3.0), "y": spot.y, "z": spot.z + rng.next_range_f(-3.0, 3.0),
				"radius": config.strike_radius,
			})

	return out


## Where on a course lightning can land: the start, every checkpoint and the finish.
func _weather_route(doc: Dictionary) -> Array[Vector3]:
	var out: Array[Vector3] = []
	for key in ["start", "finish"]:
		var spot: Variant = doc.get(key, {})
		if typeof(spot) == TYPE_DICTIONARY and (spot as Dictionary).has("at"):
			out.append(_vec(spot["at"]))
	for checkpoint in doc.get("checkpoints", []):
		if typeof(checkpoint) == TYPE_DICTIONARY and (checkpoint as Dictionary).has("at"):
			out.append(_vec(checkpoint["at"]))
	return out


static func _vec(value: Variant) -> Vector3:
	if value is Vector3:
		return value
	if value is Array and (value as Array).size() >= 3:
		return Vector3(float(value[0]), float(value[1]), float(value[2]))
	return Vector3.ZERO


## Builds [param doc] as the stage. What the server does at a round start and a handover,
## and what a client does when it is sent one.
func build_stage(doc: Dictionary) -> DotResult:
	world_clearing.emit()
	_clear_props()

	var built := stage.build(doc)

	if not built.ok:
		DotLog.error(CHANNEL, "a stage would not build", {
			"id": str(doc.get("id", "?")), "why": built.error.message,
		})
		return built

	if stage.is_course():
		course_doc = stage.doc
		arena_doc = {}
	else:
		arena_doc = stage.doc

	stage.gate_closed = phase == Phase.COUNTDOWN or stage.is_course()
	_refresh_overviews()

	# Last, once it is all standing: the bridge answers this by sending the document.
	world_rebuilt.emit()
	return built


func _place_on_start() -> void:
	var ids := players.keys()
	ids.sort_custom(func(a: StringName, b: StringName) -> bool: return String(a) < String(b))

	for seat in range(ids.size()):
		var player: WoPlayer = players[ids[seat]]
		player.reset_progress()
		_disarm(player)

		if player.health != null:
			player.health.health = config.player_health
			player.health.alive = true
			player.health.invulnerable = false

		var spot := stage.start_spot(seat, ids.size())
		player.place_at(spot[0], spot[1])
		_bot_route[player.player_id] = 0

		if spectate != null:
			spectate.on_spawned(player.player_id)


func _set_phase(to: int) -> void:
	if phase == to:
		return

	phase = to
	phase_elapsed = 0.0

	if stage != null and stage.is_course():
		stage.gate_closed = to == Phase.COUNTDOWN or to == Phase.IDLE

	phase_changed.emit(to)
	DotLog.debug(CHANNEL, "the round changed phase", {"phase": Phase.keys()[to]})


## The clock, and every decision it makes.
func _advance_phase(delta: float) -> void:
	if phase == Phase.IDLE:
		return

	phase_elapsed += delta

	match phase:
		Phase.COUNTDOWN:
			if phase_elapsed >= config.countdown_seconds:
				course_elapsed = 0.0
				_set_phase(Phase.COURSE)
		Phase.COURSE:
			course_elapsed += delta

			if _course_is_over():
				_close_course()
		Phase.HANDOVER:
			if phase_elapsed >= config.handover_seconds:
				_begin_finale()
		Phase.FINALE:
			_check_finale()


## The course's own clock: the document's, under the server's ceiling.
## [method course_limit] for a document not yet built, for drawing its weather.
func course_limit_for(doc: Dictionary) -> float:
	var asked := float(doc.get("course_seconds", 0.0))
	return minf(asked, config.course_seconds) if asked > 0.0 else config.course_seconds


func course_limit() -> float:
	var asked := float(course_doc.get("course_seconds", 0.0))
	return minf(asked, config.course_seconds) if asked > 0.0 else config.course_seconds


func _course_is_over() -> bool:
	if course_elapsed >= course_limit():
		return true

	# Everybody across. "Nobody left on the course" is the same thing here: there is no way
	# off a course but the finish, and a leaver is not on it.
	for id: StringName in players:
		var player := players[id] as WoPlayer
		# Knocked out of the round is off the course too, or a round with an elimination in
		# it always runs its clock out.
		if not player.finished and not player.watching:
			return false

	return not players.is_empty()


## The course is closed. Who finished decides what happens next.
func _close_course() -> void:
	var through := finishing_sides()

	DotLog.info(CHANNEL, "the course closed", {
		"finished": _finish_count, "sides_through": through.size(),
		"seconds": "%.1f" % course_elapsed,
	})

	if through.size() >= 2:
		_begin_handover(through)
		return

	if through.size() == 1:
		_decide(through[0], "%s finished the course" % side_name(through[0]))
		return

	if config.progress_decides:
		var furthest := _furthest_side()

		if furthest != 0:
			_decide(furthest, "%s got furthest" % side_name(furthest))
			return

	_decide(0, "nobody finished")


## Every side with somebody across the line, in the order they first got there.
func finishing_sides() -> Array[int]:
	var firsts: Dictionary = {}

	for id: StringName in players:
		var player: WoPlayer = players[id]

		if not player.finished:
			continue

		var side := int(sides.get(id, 0))

		if not firsts.has(side) or player.place < int(firsts[side]):
			firsts[side] = player.place

	var out: Array[int] = []

	for side: int in firsts:
		out.append(side)

	out.sort_custom(func(a: int, b: int) -> bool: return int(firsts[a]) < int(firsts[b]))
	return out


## The side whose best runner reached the furthest checkpoint; 0 on a tie or nobody.
func _furthest_side() -> int:
	var best := -1
	var best_side := 0
	var tied := false

	for id: StringName in players:
		var player: WoPlayer = players[id]
		var side := int(sides.get(id, 0))

		if player.checkpoint > best:
			best = player.checkpoint
			best_side = side
			tied = false
		elif player.checkpoint == best and side != best_side:
			tied = true

	return 0 if tied or best < 0 else best_side


func _decide(winner: int, why: String) -> void:
	if _decided:
		return

	_decided = true
	_winner = winner
	_winner_name = why
	DotLog.info(CHANNEL, "the round is decided", {"winner": winner, "why": why})


# --- The final death ---------------------------------------------------------

## The finishers into an arena, everybody else into its gallery, and the floor laid out.
##
## [b]A different arena, a different arrangement, a different floor every time[/b] — all of
## it drawn from the round's own seed, so a server and a replay of it agree. Which arena; which
## of its spawn areas each side is given (shuffled, so the same two sides are not always in
## the same two corners); where in its area each person stands; and where every prop and
## weapon lands inside the drop areas.
func _begin_handover(through: Array[int]) -> void:
	var stream := random.stream(&"finale")
	var doc := catalogue.pick_arena(config.arena_ids, stream) if catalogue != null \
		else WoCatalogue.practice_arena()

	_set_phase(Phase.HANDOVER)
	build_stage(doc)

	var areas: Array = stage.spawn_areas().duplicate()
	_shuffle(areas, stream)

	var watching_seat := 0

	for slot in range(through.size()):
		var side: int = through[slot]
		var area: Dictionary = areas[slot % areas.size()]
		var runners: Array[WoPlayer] = []

		for player in players_on(side):
			if player.finished:
				runners.append(player)

		for seat in range(runners.size()):
			var player: WoPlayer = runners[seat]
			var size: Vector2 = area["size"]
			var at := (area["at"] as Vector3) + Vector3(
				stream.next_range_f(-size.x * 0.4, size.x * 0.4),
				0.3,
				stream.next_range_f(-size.y * 0.4, size.y * 0.4)
			)
			# Facing the middle of the arena, the one direction that is never immediately a
			# wall or the drop.
			var inward := stage.bounds().get_center() - at
			player.place_at(at, rad_to_deg(atan2(-inward.x, -inward.z)))
			player.watching = false

			if player.health != null:
				player.health.health = config.player_health
				player.health.alive = true
				player.health.invulnerable = true

	for id: StringName in players:
		var player: WoPlayer = players[id]

		if through.has(int(sides.get(id, 0))) and player.finished:
			continue

		# Everybody else watches. Not dead — nothing can reach them in the gallery — and not
		# on any side the final death counts.
		player.watching = true
		var spot := stage.gallery_spot(watching_seat)
		watching_seat += 1
		player.place_at(spot[0], spot[1])

		if player.health != null:
			player.health.invulnerable = true

	_drop_props(through.size(), stream)
	_lay_out_weapons(through.size(), stream)

	if progress != null:
		progress.on_handover()

	DotLog.info(CHANNEL, "the final death", {
		"arena": String(stage.id()), "sides": through.size(), "props": props.world_count(),
		"weapons": pickups.size(),
	})


func _begin_finale() -> void:
	_set_phase(Phase.FINALE)

	for id: StringName in players:
		var player: WoPlayer = players[id]

		if player.health != null and not player.watching:
			player.health.invulnerable = false


## Last side standing, or the clock.
func _check_finale() -> void:
	var standing: Dictionary = {}

	for id: StringName in players:
		var player: WoPlayer = players[id]

		if player.watching or not player.is_alive():
			continue

		var side := int(sides.get(id, 0))
		standing[side] = int(standing.get(side, 0)) + 1

	if standing.size() == 1:
		var side: int = standing.keys()[0]
		_decide(side, "%s won the final death" % side_name(side))
		return

	if standing.is_empty():
		_decide(0, "nobody survived the final death")
		return

	if phase_elapsed >= config.finale_seconds:
		# The clock: the side with the most people up wins; a tie is a draw. Health would
		# break more ties and would also reward hiding, which is the one thing the clock is
		# there to stop.
		var best := 0
		var best_count := 0
		var tied := false

		for side: int in standing:
			if int(standing[side]) > best_count:
				best_count = int(standing[side])
				best = side
				tied = false
			elif int(standing[side]) == best_count:
				tied = true

		_decide(0 if tied else best, "time" if tied else "%s outlasted everybody" % side_name(best))


func _drop_props(sides_in: int, stream: DotRandomStream) -> void:
	var areas := stage.drop_areas()

	if areas.is_empty():
		return

	var ids := [WoContent.CRATE, WoContent.CRATE, WoContent.TYRE, WoContent.CONE,
		WoContent.BARREL, WoContent.BOULDER, WoContent.CRATE, WoContent.TYRE]
	var count := mini(config.finale_props_per_side * maxi(sides_in, 2), config.prop_budget)

	for i in range(count):
		var area: Dictionary = areas[stream.next_range_i(0, areas.size() - 1)]
		var size: Vector2 = area["size"]
		var at := (area["at"] as Vector3) + Vector3(
			stream.next_range_f(-size.x * 0.5, size.x * 0.5),
			2.5 + float(i % 4) * 1.2,
			stream.next_range_f(-size.y * 0.5, size.y * 0.5)
		)
		var id: StringName = ids[stream.next_range_i(0, ids.size() - 1)]
		var prop := props.spawn(id, WoContent.WORLD_OWNER, at)

		if prop != null and physics != null and prop.body() != null:
			var _applied := physics.apply_to(prop.body(), &"prop")


func _lay_out_weapons(sides_in: int, stream: DotRandomStream) -> void:
	pickups.clear()
	var areas := stage.drop_areas()
	var pool := _weapon_pool()

	if areas.is_empty() or pool.is_empty():
		return

	for i in range(config.finale_weapons_per_side * maxi(sides_in, 2)):
		var area: Dictionary = areas[stream.next_range_i(0, areas.size() - 1)]
		var size: Vector2 = area["size"]
		var at := (area["at"] as Vector3) + Vector3(
			stream.next_range_f(-size.x * 0.45, size.x * 0.45),
			0.7,
			stream.next_range_f(-size.y * 0.45, size.y * 0.45)
		)
		var weapon: StringName = pool[stream.next_range_i(0, pool.size() - 1)]
		var pickup_id := _next_pickup
		_next_pickup += 1
		pickups[pickup_id] = {"weapon": weapon, "at": at}
		pickup_placed.emit(pickup_id, weapon, at)


## Which weapons lie about. The set where every entry can win a fight, as in mg-smash-copter,
## plus the two melee weapons, because a prop and a hammer are this round's whole idea.
func _weapon_pool() -> Array[StringName]:
	var out: Array[StringName] = []

	if not config.weapon_pool.is_empty():
		for id in config.weapon_pool:
			out.append(StringName(id))
		return out

	out.append_array([
		ZeeWeaponIds.REVOLVER, ZeeWeaponIds.SMG, ZeeWeaponIds.CARBINE, ZeeWeaponIds.RIFLE,
		ZeeWeaponIds.SHOTGUN, ZeeWeaponIds.DRUM_SHOTGUN, ZeeWeaponIds.MARKSMAN,
		ZeeWeaponIds.LAUNCHER, ZeeWeaponIds.HATCHET, ZeeWeaponIds.MALLET,
	])
	return out


static func _shuffle(items: Array, stream: DotRandomStream) -> void:
	for i in range(items.size() - 1, 0, -1):
		var j := stream.next_range_i(0, i)
		var held: Variant = items[i]
		items[i] = items[j]
		items[j] = held


func _clear_props() -> void:
	if props == null:
		return

	for player: WoPlayer in players.values():
		if player.grab != null:
			var _dropped := player.grab.drop()

	for prop in props.all_props():
		var _gone := props.remove(prop.instance_id, DotPropSpawner.REASON_CLEANUP)

	_thrown.clear()

	for pickup_id: int in pickups.keys():
		pickup_taken.emit(pickup_id, &"")

	pickups.clear()


# --- Weapons -----------------------------------------------------------------

## Hands [param player] a weapon, building their rig the first time.
func arm(player: WoPlayer, weapon_id: StringName) -> bool:
	if player.weapons == null:
		var rig := ZeeWeaponRig.new()
		rig.name = "Weapons"
		# SERVER on a server: the role only decides what is DRAWN, and a headless process has
		# no art to draw a view model from.
		rig.role = ZeeWeaponRig.Role.SERVER
		rig.authority = authoritative
		rig.tick_rate = tick_rate
		rig.player_ref = DotNodeRef.of_path(player.get_path())
		player.add_child(rig)

		var ready_now := rig.setup()

		if not ready_now.ok:
			DotLog.warn(CHANNEL, "a weapon rig would not set up", {
				"player": String(player.player_id), "why": ready_now.error.message,
			})
			player.remove_child(rig)
			rig.queue_free()
			return false

		player.weapons = rig

	if not player.weapons.give(weapon_id).ok:
		return false

	var def := player.weapons.arsenal.catalogue.get_def(weapon_id)

	if def != null:
		var _selected := player.weapons.arsenal.select(def.slot, _tick)

	player_armed.emit(player.player_id, weapon_id)
	return true


func _disarm(player: WoPlayer) -> void:
	if player.grab != null:
		var _dropped := player.grab.drop()

	if player.weapons == null:
		return

	player.remove_child(player.weapons)
	player.weapons.queue_free()
	player.weapons = null


func _advance_pickups() -> void:
	if pickups.is_empty():
		return

	for id: StringName in players:
		var player: WoPlayer = players[id]

		if player.watching or not player.is_alive():
			continue

		for pickup_id: int in pickups.keys():
			var pickup: Dictionary = pickups[pickup_id]

			if player.controller.state.position.distance_to(pickup["at"]) > PICKUP_REACH + 0.7:
				continue

			if arm(player, pickup["weapon"]):
				pickups.erase(pickup_id)
				pickup_taken.emit(pickup_id, player.player_id)
				break


func _advance_weapons() -> void:
	if phase != Phase.FINALE or combat == null:
		return

	for id: StringName in players:
		var player: WoPlayer = players[id]

		if player.weapons == null or not player.is_alive() or player.watching:
			continue

		# Carrying something is both hands: the trigger throws it, and the gun stays down.
		if player.grab != null and player.grab.is_carrying():
			continue

		var outcome := player.weapons.simulate_tick(weapon_command_for(player), _tick)

		for shot in outcome.shots:
			shot.attacker = player.entity_id
			shot.tick = _tick
			var _resolved := combat.resolve_shot(shot)


## A player's movement command as a weapon command: fire, alt-fire and reload are the
## movement command's three spare buttons; the slot is this game's own input message.
func weapon_command_for(player: WoPlayer) -> DotWeaponCommand:
	var command := DotWeaponCommand.new()
	var pending := player.controller.current_command

	if pending == null:
		return command

	command.set_button(DotWeaponCommand.BUTTON_ATTACK, pending.is_pressed(DotFpsCommand.BUTTON_USER_0))
	command.set_button(DotWeaponCommand.BUTTON_ALT, pending.is_pressed(DotFpsCommand.BUTTON_USER_1))
	command.set_button(DotWeaponCommand.BUTTON_RELOAD, pending.is_pressed(DotFpsCommand.BUTTON_USER_2))
	command.yaw = pending.yaw
	command.pitch = pending.pitch
	command.slot = player.wanted_slot
	return command


# --- Picking things up and throwing them ----------------------------------------

## Each player's hand: pick up what they are looking at, carry it, throw it on the trigger.
##
## [b]dot-props' gravity gun, one per player, and the server's alone.[/b] A prop is not
## predicted anywhere in this family (two solvers diverge), so neither is carrying one: the
## client presses the key, the server moves the prop, and the prop arrives in a snapshot like
## every other. The grab is an edge — the key's state rides in [WoNetCommand] — so holding it
## is one pick-up rather than a pick-up and a drop every other tick.
func _advance_grabs(delta: float) -> void:
	if phase != Phase.FINALE and phase != Phase.HANDOVER:
		return

	var space := get_world_3d().direct_space_state if get_world_3d() != null else null

	for id: StringName in players:
		var player: WoPlayer = players[id]

		if player.watching or not player.is_alive():
			continue

		if player.grab == null:
			player.grab = DotGravGun.new()
			player.grab.spawner = props
			player.grab.wielder = player.player_id
			player.grab.reach = GRAB_REACH
			player.grab.carry_distance = 2.2
			player.grab.punt_impulse = config.throw_impulse

		var pressed := player.wants_grab and not bool(player.get_meta(&"grab_held", false))
		player.set_meta(&"grab_held", player.wants_grab)

		var eyes := player.eye_position()
		var aim := player.aim_direction()

		if pressed:
			if player.grab.is_carrying():
				var _put := player.grab.drop()
			elif space != null:
				var _took := player.grab.pull(space, eyes, aim)

		if not player.grab.is_carrying():
			continue

		player.grab.carry(eyes, aim, delta)

		var pending := player.controller.current_command

		if pending != null and pending.is_pressed(DotFpsCommand.BUTTON_USER_0) and phase == Phase.FINALE:
			var thrown := player.grab.punt(space, eyes, aim)

			if thrown != null:
				_thrown[thrown.instance_id] = {"by": player.player_id, "until": _tick + int(THROWN_SECONDS * tick_rate)}


## A thrown prop that meets somebody hurts them, by its momentum, and knocks them back.
func _watch_thrown() -> void:
	if _thrown.is_empty() or combat == null:
		return

	for instance_id: int in _thrown.keys():
		var entry: Dictionary = _thrown[instance_id]
		var prop := props.get_prop(instance_id)

		if prop == null or not prop.is_alive() or _tick > int(entry["until"]):
			_thrown.erase(instance_id)
			continue

		var body := prop.body()

		if body == null:
			continue

		var speed := body.linear_velocity.length()

		if speed < config.throw_hurt_speed:
			continue

		for id: StringName in players:
			var player: WoPlayer = players[id]

			if player.watching or not player.is_alive() or id == StringName(entry["by"]):
				continue

			var middle := player.controller.state.position + Vector3(0.0, 0.9, 0.0)

			if middle.distance_to(body.global_position) > 1.3:
				continue

			if int(_thrown_hit.get(id, -1000)) > _tick - 20:
				continue

			_thrown_hit[id] = _tick
			var thrower: WoPlayer = players.get(StringName(entry["by"]))
			var damage := DotDamage.make(
				thrower.entity_id if thrower != null else 0, player.entity_id,
				prop.def.mass * speed * config.throw_damage_per_impulse, null
			)
			damage.point = middle
			damage.direction = body.linear_velocity.normalized()
			damage.tick = _tick
			damage.context = {"why": DIED_THROWN}
			var _applied := combat.apply_damage(damage)

			var shove := body.linear_velocity
			shove.y = 0.0
			player.controller.state.velocity += shove.normalized() * minf(speed * 0.6, 12.0) \
				+ Vector3.UP * 4.0
			player.controller.state.mode = DotFpsState.Mode.AIR


func _on_prop_exploded(
	at: Vector3, radius: float, damage_amount: float, force: float, by: StringName
) -> void:
	blast.emit(at, radius)

	if combat == null:
		return

	var attacker := 0

	if players.has(by):
		attacker = (players[by] as WoPlayer).entity_id

	for id: StringName in players:
		var player: WoPlayer = players[id]

		if not player.is_alive() or player.watching:
			continue

		var offset := player.controller.state.position - at
		var distance := offset.length()

		if distance > radius:
			continue

		var falloff := 1.0 - (distance / radius)
		var damage := DotDamage.make(attacker, player.entity_id, damage_amount * falloff, null)
		damage.point = player.controller.state.position
		damage.direction = offset.normalized() if distance > 0.01 else Vector3.UP
		damage.tick = _tick
		damage.context = {"why": DIED_BLAST}
		var _applied := combat.apply_damage(damage)
		player.controller.state.velocity += damage.direction * force * falloff * 0.0035 \
			+ Vector3.UP * falloff * 4.5


# --- The tick ---------------------------------------------------------------

func _physics_process(delta: float) -> void:
	if not authoritative or match_node == null or external_tick:
		return

	simulate(delta)


## One tick, counted by this world. What an offline client and the suite use.
func simulate(delta: float) -> void:
	_tick += 1
	_step(delta)


## One tick, numbered by the netcode. What the bridge uses. The step is still a fixed
## `1 / tick_rate`; a simulation stepped by a frame's delta runs differently on a bad second.
func tick_once(tick: int) -> void:
	if match_node == null:
		return

	_tick = tick
	_step(delta_for_tick())


func current_tick() -> int:
	return _tick


func _step(delta: float) -> void:
	_advance_phase(delta)

	if stage != null:
		stage.pose_at(_tick)

	_drive_bots()

	for id: StringName in players:
		(players[id] as WoPlayer).simulate(_tick, delta)

	_watch_progress()
	_advance_pickups()
	_advance_grabs(delta)
	_watch_thrown()
	_advance_weapons()

	if combat != null:
		combat.tick(_tick, delta)

	if spectate != null:
		spectate.advance(_tick)

	if not sides_are_playable() and phase == Phase.IDLE:
		return

	match_node.tick(_tick)


func delta_for_tick() -> float:
	return 1.0 / float(maxi(tick_rate, 1))


## Adopts a tick rate, on a client being told what the server runs at: this world, every
## player's controller and the stage, or the client walks at the wrong speed and is
## corrected for it on every snapshot.
func set_tick_rate(rate: int) -> bool:
	if rate <= 0 or rate == tick_rate:
		return false

	tick_rate = rate

	if stage != null:
		stage.tick_rate = rate

	for id: StringName in players:
		(players[id] as WoPlayer).tick_rate = rate

	if match_node != null and match_node.config != null:
		match_node.config.tick_rate = rate

	return true


## Falls, checkpoints and the finish: everything about a runner that is the server's to say.
##
## [b]A height comparison, not a trigger volume,[/b] for the fall: something falling fast
## crosses a thin trigger between two ticks without ever being inside it, which is dot-timer's
## own note and mg-smash-copter's floor.
func _watch_progress() -> void:
	if stage == null or stage.doc.is_empty():
		return

	for id: StringName in players:
		var player: WoPlayer = players[id]
		var feet := player.controller.state.position

		# The knock happens inside the player's own tick (see [WoPlayer]); this is where the
		# server notices one happened, for the numbers.
		if player.knocks > int(player.get_meta(&"knocks_seen", 0)):
			player.set_meta(&"knocks_seen", player.knocks)

			if progress != null:
				progress.on_knocked(id)

			# What the knock costs. On the course only, on the authority only: the throw was
			# predicted, the health is decided.
			if authoritative and stage.is_course() and phase == Phase.COURSE and combat != null \
					and player.is_alive() and not player.finished:
				var amount := player.last_knock_speed * config.knock_damage_per_speed
				if player.last_knock_struck:
					amount = maxf(amount, config.strike_damage)
				if amount > 0.0:
					var hurt := DotDamage.make(0, player.entity_id, amount, null)
					hurt.point = feet
					hurt.tick = _tick
					hurt.context = {"why": DIED_STRUCK if player.last_knock_struck else DIED_KNOCKED}
					var _applied := combat.apply_damage(hurt)

		if feet.y < stage.water_height():
			_fell(player)
			continue

		if not stage.is_course() or player.finished or phase != Phase.COURSE:
			continue

		var crossed := stage.checkpoint_at(feet)

		if crossed > player.checkpoint:
			player.checkpoint = crossed
			checkpoint_reached.emit(id, crossed)
			if config.checkpoint_heals and authoritative and player.health != null:
				var _healed := player.health.heal(player.health.max_health)

		if stage.in_finish(feet):
			_finish(player)


func _fell(player: WoPlayer) -> void:
	if stage.is_arena():
		if player.watching:
			var spot := stage.gallery_spot(0)
			player.place_at(spot[0], spot[1])
			return

		if player.is_alive() and combat != null:
			var damage := DotDamage.make(0, player.entity_id, player.health.max_health * 4.0, null)
			damage.point = player.controller.state.position
			damage.direction = Vector3.DOWN
			damage.tick = _tick
			damage.context = {"why": DIED_FELL}
			var _applied := combat.apply_damage(damage)
		return

	# On a course a fall costs time and nothing else: back to the last checkpoint crossed,
	# or the start, or — for somebody already finished — the lounge.
	player.falls += 1

	if player.finished:
		var spot := stage.lounge_spot(player.place)
		player.place_at(spot[0], spot[1])
	else:
		var spot := stage.respawn_point(player.checkpoint, player.falls % 5)
		player.place_at(spot[0], spot[1])

	if player.is_bot:
		_bot_route[player.player_id] = _route_after(player.controller.state.position)

	if progress != null:
		progress.on_fell(player.player_id)

	player_fell.emit(player.player_id, player.checkpoint)


func _finish(player: WoPlayer) -> void:
	_finish_count += 1
	player.finished = true
	player.place = _finish_count
	player.finish_seconds = course_elapsed

	if progress != null:
		progress.on_finished(player.player_id, player.place, course_elapsed)

	player_finished.emit(player.player_id, player.place, course_elapsed)
	DotLog.debug(CHANNEL, "somebody finished", {
		"id": String(player.player_id), "place": player.place, "seconds": "%.2f" % course_elapsed,
	})


# --- Bots -------------------------------------------------------------------

## What a stand-in does. On a course: follow the document's route, jump where it says, and
## sometimes get it wrong. In a final death: get something in its hands and use it.
func _drive_bots() -> void:
	for id: StringName in players:
		var player: WoPlayer = players[id]

		if not player.is_bot or not player.is_alive():
			continue

		var command := DotFpsCommand.new()
		command.yaw = player.controller.state.yaw
		command.pitch = player.controller.state.pitch

		if player.watching or phase == Phase.IDLE or phase == Phase.COUNTDOWN:
			pass
		elif stage.is_course() and not player.finished:
			_bot_run(player, command)
		elif phase == Phase.FINALE:
			_bot_fight(player, command)

		player.controller.apply_command(command)


func _bot_run(player: WoPlayer, command: DotFpsCommand) -> void:
	var route := stage.route()

	if route.is_empty():
		return

	var index := mini(int(_bot_route.get(player.player_id, 0)), route.size() - 1)
	var point: Dictionary = route[index]
	var next: Dictionary = route[index + 1] if index + 1 < route.size() else {}
	var at := player.controller.state.position
	var toward: Vector3 = (point["at"] as Vector3) - at
	toward.y = 0.0
	var grounded := player.controller.state.mode == DotFpsState.Mode.GROUND

	command.yaw = rad_to_deg(atan2(-toward.x, -toward.z))
	command.move = Vector2(0.0, 1.0)

	# In the air, aimed at a top to land on: brake if the jump is going to carry past it.
	if not grounded and bool(point["jump"]):
		_bot_land_on(player, command, point["at"])

	# A point ON something that moves is reached by standing on it, wherever it has got to:
	# chasing the coordinates the mover started from walked the bot backwards off its tail.
	if bool(point["ride"]) and grounded and stage.carries(player.controller.state.ground_id):
		_bot_wait.erase(player.player_id)
		_bot_route[player.player_id] = index + 1
		command.move = Vector2.ZERO
		return

	# Something to land on: nothing is started until it will be there. Asked every tick, so
	# a bot riding a mover stays on it, carried, until the far side is in reach.
	if bool(point["board"]) and grounded:
		var waited := int(_bot_wait.get(player.player_id, 0))

		# Six seconds at the most: a window that never comes is a course to fix, and a bot
		# standing still for ever would hide that rather than show it.
		if waited < tick_rate * 6 and not _bot_may_board(player, point):
			_bot_wait[player.player_id] = waited + 1
			command.move = Vector2.ZERO
			return

	# Walked into, for its last metre and a half, a point the bot may have to stop at: one that
	# arrived at a run and then stopped slid a metre past it, which beside a mover is off the
	# edge. Not further out: a bot walking the last two and a half metres walked through the
	# ram it had timed its window for at a run.
	var stops := bool(point["wait"]) or (not next.is_empty() and bool(next["board"]))

	# Only on the way IN: a bot let go from a wait point timed its window at a run, and one
	# that walked through it arrived late and was hit — every pusher on Punch Alley, every time.
	if bool(point["walk"]) or (stops and toward.length() < 1.6 and toward.length() > float(point["reach"])):
		command.set_button(DotFpsCommand.BUTTON_WALK, true)

	_bot_hop(player, command)
	_bot_unstick(player, command)

	# Heading for something to land on, the jump is at whatever edge the bot reaches first,
	# which on a moving floor is nowhere a route point could name. A gap a stride crosses is
	# stepped, not jumped: a running jump is nearly five metres, and jumping the thirty
	# centimetres between a deck and a mover beside it carried the bot clean over the mover.
	if bool(point["board"]) and grounded:
		var heading := Vector3(-sin(deg_to_rad(command.yaw)), 0.0, -cos(deg_to_rad(command.yaw)))

		if not stage.supported(at + heading * 0.7 + Vector3(0.0, 0.1, 0.0), _tick) \
				and not stage.supported(at + heading * 1.6 + Vector3(0.0, 0.1, 0.0), _tick):
			command.set_button(DotFpsCommand.BUTTON_JUMP, true)

	if toward.length() > float(point["reach"]):
		return

	if bool(point["wait"]) and not next.is_empty():
		var waited := int(_bot_wait.get(player.player_id, 0))

		if waited < tick_rate * 6 and not stage.path_clear(at, next["at"], _tick, config.run_speed):
			_bot_wait[player.player_id] = waited + 1
			command.move = Vector2.ZERO
			command.set_button(DotFpsCommand.BUTTON_JUMP, false)
			return

	_bot_wait.erase(player.player_id)

	# A jump point passed in the air is not passed: it is where the NEXT jump starts, and
	# advancing on it mid-flight meant the bot came down on a ball, never jumped off it and
	# slid into the water. Held until the bot is on its feet.
	if bool(point["jump"]):
		if not grounded:
			return

		# Up to speed first, for a few ticks: a landing on a ball or a turning log costs speed,
		# and a jump taken at four metres a second off a log falls short of the next one — a
		# jump is cut short in the air, never stretched.
		var flat_speed := Vector2(player.controller.state.velocity.x, player.controller.state.velocity.z).length()
		var spent := int(_bot_runup.get(player.player_id, 0))

		if flat_speed < config.run_speed * 0.85 and spent < 3:
			_bot_runup[player.player_id] = spent + 1
			return

		_bot_runup.erase(player.player_id)

		# A fumble is a jump not taken, decided once per bot, waypoint and round, so it is
		# reproducible and a different bot fumbles a different jump.
		var draw := random.stream_for(&"bot_fumble",
			round_number * 65536 + int(player.entity_id % 256) * 256 + index)

		if draw.next_range_f(0.0, 100.0) >= config.bot_fumble_chance:
			command.set_button(DotFpsCommand.BUTTON_JUMP, true)

	_bot_route[player.player_id] = index + 1


## Steers a bot in the air so it comes down on [param target] rather than past it.
##
## [b]A top is small and a running jump is long.[/b] A bot that jumps the moment it lands on
## a ball takes off at whatever speed the landing left it, so the next jump is anywhere from
## three and a half to five metres — and five metres past a ball's top is its far side. The
## motor's air control brakes hard when the wish is against the motion (it is the same
## arithmetic that lets a person stop a jump short), so this predicts where the jump comes
## down at the target's height and holds BACK while that is past it.
func _bot_land_on(player: WoPlayer, command: DotFpsCommand, target: Vector3) -> void:
	var state := player.controller.state
	var flat := Vector3(target.x - state.position.x, 0.0, target.z - state.position.z)

	if flat.length() > 7.0:
		return

	var g := config.gravity
	var rise := target.y - state.position.y
	var root := state.velocity.y * state.velocity.y - 2.0 * g * rise

	if root < 0.0:
		return

	var falls_in := (state.velocity.y + sqrt(root)) / g
	var drift := Vector3(state.velocity.x, 0.0, state.velocity.z) * falls_in
	var along := drift.dot(flat.normalized())

	command.yaw = rad_to_deg(atan2(-flat.x, -flat.z))
	var over := along - flat.length()

	if over <= 0.25 or falls_in <= 0.02:
		# Nothing in: no wish adds nothing to a jump already at speed, and the jump lands
		# where it was always going to.
		command.move = Vector2.ZERO
		return

	# Proportional, and full back is far too much: the motor takes over three metres a second
	# off a jump in ONE tick when the wish is fully against it, and the first version stopped
	# every jump dead a metre off the deck. The slowdown needed, spread over the ticks left.
	var ticks_left := maxf(falls_in * float(tick_rate), 1.0)
	var per_tick := over / falls_in / ticks_left
	var full := config.run_speed * 30.0 / float(tick_rate)
	command.move = Vector2(0.0, -clampf(per_tick / full, 0.02, 1.0))


## Jumps when the bot has been running for a second and got nowhere.
##
## [b]A turning log's steep side is a treadmill.[/b] A bot running up it at exactly the speed
## the log turns back stayed on the same spot for half a minute at a time — every number
## correct, the course just never ending. A person in that spot jumps; so does this.
func _bot_unstick(player: WoPlayer, command: DotFpsCommand) -> void:
	var at := player.controller.state.position
	var mark: Array = _bot_stuck.get(player.player_id, [])

	# Letting go, for half a second after being stuck on something too steep to jump from.
	if mark.size() > 2 and _tick < int(mark[2]):
		command.move = Vector2.ZERO
		return

	if mark.is_empty() or _tick - int(mark[1]) >= tick_rate:
		var stuck := not mark.is_empty() and command.move != Vector2.ZERO \
			and Vector2(at.x - (mark[0] as Vector3).x, at.z - (mark[0] as Vector3).z).length() < 0.4
		var release := -1

		if stuck and player.controller.state.mode == DotFpsState.Mode.GROUND:
			command.set_button(DotFpsCommand.BUTTON_JUMP, true)
		elif stuck:
			# On a face too steep to stand on, the motor has the bot sliding, and a slide is not
			# ground to jump from. Stop pushing and drop: a restart costs seconds, the treadmill
			# cost minutes.
			release = _tick + tick_rate / 2

		_bot_stuck[player.player_id] = [at, _tick, release]


## Jumps whatever low thing is about to sweep through where the bot is running, and ducks
## whatever high thing is.
##
## [b]A person jumps a low arm; they do not wait for a gap it never leaves.[/b] A sweeper
## with two arms at eighty degrees a second covers a six-metre deck for most of every turn,
## so "wait until the way is clear" waits for ever. This asks the course about the next
## half second along the bot's own heading, and jumps when an arm is due between a fifth and
## a half of a second from now — the part of a jump when the feet are above a low arm.
func _bot_hop(player: WoPlayer, command: DotFpsCommand) -> void:
	if player.controller.state.mode != DotFpsState.Mode.GROUND or command.move == Vector2.ZERO:
		return

	var heading := Vector3(-sin(deg_to_rad(command.yaw)), 0.0, -cos(deg_to_rad(command.yaw)))
	var at := player.controller.state.position
	var limits := Vector3(1.0, 1.0, 1.0)
	var duck := false
	var jump := false
	var high_arm := stage.high_arm_near(at, 3.0)

	# The same three moments the hop always asked about (a fifth to two fifths of a second:
	# when a jump's feet are over a low arm), plus the two either side for the duck, which
	# has to start earlier and last longer.
	for step in [0.0, 0.2, 0.3, 0.4, 0.6]:
		var ahead: float = step
		# Crouched, a bot runs at the crouch speed; standing, at the run.
		var where_standing := at + heading * config.run_speed * ahead
		var tick := _tick + int(ahead * tick_rate)

		if stage.knock(where_standing, false, tick, limits) == Vector3.ZERO:
			continue

		# [b]A high arm is ducked, never jumped.[/b] If crouching clears what standing does
		# not, the arm is high; jumping into it is the one wrong answer, and the hop below
		# would give it, because all it knows is that something is coming.
		var where_crouched := at + heading * config.run_speed * 0.4 * ahead

		if high_arm and stage.knock(where_crouched, true, tick, limits) == Vector3.ZERO:
			duck = true
		elif ahead >= 0.2 and ahead <= 0.4:
			jump = true

	if duck:
		command.set_button(DotFpsCommand.BUTTON_CROUCH, true)
	elif jump:
		command.set_button(DotFpsCommand.BUTTON_JUMP, true)


## Whether [param point] — something to land on — will be under a jump that sets off now:
## near enough to reach at a run, and there when the bot comes down and a moment after.
func _bot_may_board(player: WoPlayer, point: Dictionary) -> bool:
	var from := player.controller.state.position
	var to: Vector3 = point["at"]
	var distance := Vector2(to.x - from.x, to.z - from.z).length()

	# A ride that has not brought the bot this close yet is a ride to stay on.
	if distance > 5.0:
		return false

	var lands := _tick + int(distance / maxf(config.run_speed, 0.5) * float(tick_rate)) + tick_rate / 8
	return stage.supported(to, lands) and stage.supported(to, lands + tick_rate / 4)


## The route point a bot should head for from [param at]: the nearest one, then onward.
func _route_after(at: Vector3) -> int:
	var route := stage.route()
	var best := 0
	var best_distance := INF

	for index in range(route.size()):
		var distance := at.distance_to((route[index] as Dictionary)["at"])

		if distance < best_distance:
			best_distance = distance
			best = index

	return best


func _bot_fight(player: WoPlayer, command: DotFpsCommand) -> void:
	var at := player.controller.state.position
	var enemy := _nearest_enemy(player)

	if player.weapons != null and enemy != null:
		_aim_bot(player, command, enemy)
		var distance := enemy.controller.state.position.distance_to(at)

		if distance > 7.0:
			command.move = Vector2(0.0, 1.0)

		return

	# Nothing in hand: the nearest weapon, then the nearest prop, then walk at somebody.
	var target := Vector3.INF
	var best := INF

	for pickup_id: int in pickups:
		var spot: Vector3 = (pickups[pickup_id] as Dictionary)["at"]
		var distance := spot.distance_to(at)

		if distance < best:
			best = distance
			target = spot

	if player.grab != null and player.grab.is_carrying() and enemy != null:
		_aim_bot(player, command, enemy)
		command.set_button(DotFpsCommand.BUTTON_USER_0,
			enemy.controller.state.position.distance_to(at) < 9.0)
		command.move = Vector2(0.0, 1.0)
		player.wants_grab = false
		return

	if target == Vector3.INF:
		for prop in props.all_props():
			var body := prop.body()

			if body == null:
				continue

			var distance := body.global_position.distance_to(at)

			if distance < best:
				best = distance
				target = body.global_position

		if target != Vector3.INF and best < GRAB_REACH - 0.6:
			var look := target - player.eye_position()
			command.yaw = rad_to_deg(atan2(-look.x, -look.z))
			command.pitch = clampf(rad_to_deg(asin(clampf(look.normalized().y, -1.0, 1.0))), -89.0, 89.0)
			player.wants_grab = not player.wants_grab
			return

	if target == Vector3.INF and enemy != null:
		target = enemy.controller.state.position

	if target != Vector3.INF:
		var toward := target - at
		toward.y = 0.0
		command.yaw = rad_to_deg(atan2(-toward.x, -toward.z))
		command.move = Vector2(0.0, 1.0)


func _nearest_enemy(player: WoPlayer) -> WoPlayer:
	var best: WoPlayer = null
	var closest := INF

	for id: StringName in players:
		var other: WoPlayer = players[id]

		if other == player or not other.is_alive() or other.watching:
			continue

		if int(sides.get(id, 0)) == player.team:
			continue

		var distance := other.controller.state.position.distance_to(player.controller.state.position)

		if distance < closest:
			closest = distance
			best = other

	return best


func _aim_bot(player: WoPlayer, command: DotFpsCommand, target: WoPlayer) -> void:
	var toward := target.eye_position() - player.eye_position()

	if toward.length() < 0.01:
		return

	# A hand of its own per bot per round, with the round mixed into the subject: without it
	# mg-smash-copter's empty server played the same fight twelve times out of twelve.
	var hand: Variant = _bot_hands.get(player.player_id)

	if hand == null:
		var draw := random.stream_for(&"bot_aim", round_number * 8192 + int(player.entity_id % 8192))
		var spread := config.bot_aim_spread_degrees
		hand = Vector2(draw.next_range_f(-spread, spread), draw.next_range_f(-spread * 0.4, spread * 0.4))
		_bot_hands[player.player_id] = hand

	command.yaw = rad_to_deg(atan2(-toward.x, -toward.z)) + (hand as Vector2).x
	command.pitch = clampf(
		rad_to_deg(asin(clampf(toward.normalized().y, -1.0, 1.0))) + (hand as Vector2).y, -89.0, 89.0
	)
	command.set_button(DotFpsCommand.BUTTON_USER_0, true)


# --- Reacting ---------------------------------------------------------------

func _on_player_died(player: WoPlayer, damage: DotDamage) -> void:
	var by := entities.key_for_id(damage.attacker)
	var why: StringName = damage.context.get("why", DIED_SHOT)

	if player.grab != null:
		var _dropped := player.grab.drop()

	# Spectating and progress BEFORE dot-match: `report_kill` can end the round inside the
	# call, and a kill counted after that is counted in no round. mg-smash-copter's finding.
	if spectate != null and authoritative:
		spectate.on_died(
			player.player_id, by, why == DIED_FELL,
			damage.point if damage.point != Vector3.ZERO else player.global_position,
			stage.water_height() + 8.0, _tick
		)

	if progress != null:
		progress.on_died(player.player_id, by, why == DIED_FELL, true)

	if match_node != null and DotEntity.is_kind(player.entity_id, DotEntity.KIND_PLAYER):
		match_node.report_kill(String(by), String(player.player_id), why, _tick)

	player_died.emit(player.player_id, by, why)

	# On the course a death is either the round over for them (the brief's "fatal", the
	# default) or a restart at the last checkpoint. Either way they are alive again at once:
	# an eliminated player watches from the lounge, untouchable, until the next round.
	if authoritative and stage != null and stage.is_course() and not player.finished:
		if player.health != null:
			player.health.health = config.player_health
			player.health.alive = true
		if config.course_deaths_eliminate:
			player.watching = true
			if player.health != null:
				player.health.invulnerable = true
			var seat := stage.lounge_spot(20 + players.size())
			player.place_at(seat[0], seat[1])
		else:
			var spot := stage.respawn_point(player.checkpoint, player.falls % 5)
			player.place_at(spot[0], spot[1])

	DotLog.debug(CHANNEL, "player died", {
		"id": String(player.player_id), "by": String(by), "why": String(why),
	})


# --- Reporting --------------------------------------------------------------

func seconds_left() -> float:
	match phase:
		Phase.COUNTDOWN:
			return maxf(config.countdown_seconds - phase_elapsed, 0.0)
		Phase.COURSE:
			return maxf(course_limit() - course_elapsed, 0.0)
		Phase.HANDOVER:
			return maxf(config.handover_seconds - phase_elapsed, 0.0)
		Phase.FINALE:
			return maxf(config.finale_seconds - phase_elapsed, 0.0)
		_:
			return 0.0


func describe() -> Dictionary:
	return {
		"round": round_number,
		"phase": Phase.keys()[phase],
		"left": "%.0f s" % seconds_left(),
		"course": str(course_doc.get("id", "-")),
		"arena": str(arena_doc.get("id", "-")),
		"players": players.size(),
		"finished": finished_count(),
		"alive": alive_count(),
		"props": props.world_count() if props != null else 0,
		"pickups": pickups.size(),
		"decided": _winner_name if _decided else "-",
		"courses": catalogue.courses.size() if catalogue != null else 0,
		"arenas": catalogue.arenas.size() if catalogue != null else 0,
		"phase_id": phase,
	}


func describe_lines() -> PackedStringArray:
	var lines := PackedStringArray(["wipeout, round %d" % round_number])
	var facts := describe()

	for key: String in facts:
		lines.append("  %-10s %s" % [key, facts[key]])

	if stage != null:
		lines.append_array(stage.describe_lines())

	return lines
