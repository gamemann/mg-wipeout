extends Node

const WoPlayer := preload("wo_player.gd")

## What a player keeps from a round: the numbers this game produces, and what they earn.
##
## [b]The numbers are the ones only this game has.[/b] A deathmatch counts kills; an obstacle
## course's interesting figures are about the course — how many somebody finished, how many
## they won outright, how often they fell in and how often an arm threw them. Each is declared
## once, in
## [method schema], counted as it happens and reported by dot-stats as a DELTA — "add one",
## never "now has forty" — so two servers reporting one player add up rather than overwrite.
##
## [b]Achievements are rules over those numbers and nothing else.[/b] dot-achievements never
## hears about a course or an arm; it hears that a number moved, through
## [DotAchievementStatsLink] — which is the differencer between dot-stats' SESSION totals
## and a lifetime total, and the reason this is not one `connect`. Wiring `recorded` straight
## into `record` would add the running total to the lifetime total on every reading.
##
## [b]Stand-ins are never counted.[/b] An empty server here is a server full of them, and an
## achievement a bot can earn is noise in every log an operator reads; a stand-in's numbers
## are also no player's numbers, so reporting them would be filing figures against nobody.
##
## [b]Server side, and on an offline client — wherever the world is authoritative.[/b] A
## connected client's world decides nothing, so it counts nothing; what a player is told is
## a notice from the server when they earn something.
##
## [b]A player's numbers are filed under their scoped profile key when they have one[/b] —
## dot-user's per-server derivation, which outlives a connection and can never carry a site
## account id (dot-stats' reporter refuses a `backbone:` key before it leaves the process,
## and this one is not one). [member durable_key_fn] supplies it; without one, or for a
## guest dot-user keeps no profile for, the key is the world's id, `u<session>`, and lasts a
## connection. The world's ids stay the world's: only what is handed to dot-stats and
## dot-achievements changes, through [method _key].
##
## [b]Fixed when counting begins, for the rest of the session.[/b] Counting begins on a
## player's first number, which is nearly always after dot-platform has admitted them; one
## who scored before their profile arrived keeps the session key until they reconnect,
## because moving half a session's numbers to another key mid-flight would file the second
## half against a total the first half never reached.

const CHANNEL := "wo.progress"

# --- The numbers -------------------------------------------------------------

## Rounds a player was in from the start to the end.
const ROUNDS_PLAYED := &"wo.rounds_played"
## A course crossed before it closed.
const COURSES_FINISHED := &"wo.courses_finished"
## A course crossed first.
const COURSES_FIRST := &"wo.courses_first"
const ROUNDS_WON := &"wo.rounds_won"
## A final death won, still standing in it.
const FINALE_WINS := &"wo.finale_wins"
const FINALE_KILLS := &"wo.finale_kills"
const BEST_ROUND_KILLS := &"wo.best_round_kills"
const DEATHS := &"wo.deaths"
## Into the water on a course: a restart from the last checkpoint, not a death.
const FALLS := &"wo.falls"
## Thrown by an arm, a pendulum or a pusher.
const KNOCKS := &"wo.knocks"
## A course finished without falling in once.
const CLEAN_RUNS := &"wo.clean_runs"

signal earned(player_id: StringName, title: String, points: int)

var stats: DotStatsTracker = null
var achievements: DotAchievementTracker = null
var link: DotAchievementStatsLink = null

## The world's own dictionaries, shared. See [WoSpectate] for why not a reference to it.
var players: Dictionary = {}
var sides: Dictionary = {}

## Metres from a landing inside which a player was not "missed". The world's own hurt
## radius, handed in rather than copied.

## Players present when this round began. Only they have played it.
var _in_round: Dictionary = {}

## player id -> kills in this round, for [constant BEST_ROUND_KILLS].
var _round_kills: Dictionary = {}

## Whether this round reached the corners.
var _reached_finale: bool = false

## `func(player_id: StringName) -> String`: the durable key to file this player under, or
## "" for none. Set by the module from dot-platform; see the class note.
var durable_key_fn: Callable = Callable()

## World id -> the key their numbers are filed under, and back. Fixed at [method record]'s
## first reading for them.
var _keys: Dictionary = {}
var _ids: Dictionary = {}


# --- The documents -----------------------------------------------------------

static func ids() -> Array[StringName]:
	return [
		ROUNDS_PLAYED, COURSES_FINISHED, COURSES_FIRST, ROUNDS_WON, FINALE_WINS, FINALE_KILLS,
		BEST_ROUND_KILLS, DEATHS, FALLS, KNOCKS, CLEAN_RUNS,
	]


## Every number, once. [b]`publish` on the ones a player page would show[/b]; deaths and
## rounds played are inputs to a ratio rather than figures anybody reads.
static func schema() -> DotStatsSchema:
	var out := DotStatsSchema.new()
	_add(out, ROUNDS_PLAYED, DotStatsDef.Kind.COUNTER, "Rounds played", "rounds", false)
	_add(out, COURSES_FINISHED, DotStatsDef.Kind.COUNTER, "Courses finished", "courses", true)
	_add(out, COURSES_FIRST, DotStatsDef.Kind.COUNTER, "Courses finished first", "courses", true)
	_add(out, ROUNDS_WON, DotStatsDef.Kind.COUNTER, "Rounds won", "rounds", true)
	_add(out, FINALE_WINS, DotStatsDef.Kind.COUNTER, "Final deaths won", "rounds", true)
	_add(out, FINALE_KILLS, DotStatsDef.Kind.COUNTER, "Final death knockouts", "kills", true)
	_add(out, BEST_ROUND_KILLS, DotStatsDef.Kind.BEST, "Best final death", "kills", true)
	_add(out, DEATHS, DotStatsDef.Kind.COUNTER, "Deaths", "deaths", false)
	_add(out, FALLS, DotStatsDef.Kind.COUNTER, "Falls", "falls", true)
	_add(out, KNOCKS, DotStatsDef.Kind.COUNTER, "Wiped out", "knocks", true)
	_add(out, CLEAN_RUNS, DotStatsDef.Kind.COUNTER, "Clean runs", "courses", true)
	return out


static func _add(
	out: DotStatsSchema, id: StringName, kind: DotStatsDef.Kind, display: String,
	unit: String, publish: bool
) -> void:
	var def := DotStatsDef.make(id, kind, display)
	def.unit = unit
	def.publish = publish
	out.stats.append(def)


## What a player can earn, as rules over [method schema]'s numbers.
##
## [b]Every stat read here is one [method schema] declares and this file records[/b] — an
## achievement over a stat nothing reports never unlocks and nothing errors, which is this
## family's most repeated bug wearing a rosette. The suite checks it both ways.
##
## One stat, one merge: everything is SUM except the best round, which is HIGHEST —
## dot-achievements refuses a catalogue that reads one number both ways.
static func catalogue() -> DotAchievementCatalogue:
	var made: Array[DotAchievement] = []

	made.append(_sum(&"wo.across_the_line", "Across the Line", COURSES_FINISHED, 1.0, 10,
		"Finish a course before it closes.", &"wo.finisher", 1))
	made.append(_sum(&"wo.course_regular", "Course Regular", COURSES_FINISHED, 25.0, 30,
		"Finish twenty-five courses.", &"wo.finisher", 2))
	made.append(_sum(&"wo.first_across", "First Across", COURSES_FIRST, 1.0, 20,
		"Be the first across the finish."))
	made.append(_sum(&"wo.not_a_drop", "Not a Drop", CLEAN_RUNS, 1.0, 25,
		"Finish a course without falling in once."))
	made.append(_sum(&"wo.last_one_dry", "Last One Dry", FINALE_WINS, 1.0, 20,
		"Win a final death, still standing in it."))
	made.append(_sum(&"wo.heavy_hitter", "Heavy Hitter", FINALE_KILLS, 10.0, 25,
		"Put ten people out of final deaths."))

	# A BEST: three in one final death, not three over a career.
	var sweep := DotAchievement.make(&"wo.clean_sweep", "Clean Sweep", [
		DotAchievementRule.make(
			BEST_ROUND_KILLS, 3.0, DotAchievementRule.Op.AT_LEAST,
			DotAchievementRule.Merge.HIGHEST
		),
	])
	sweep.description = "Put three people out in one final death."
	sweep.points = 30
	made.append(sweep)

	# Secret: both are earned by the thing the game is named after, which a player does long
	# before they know there is anything to earn — and the joke only works afterwards.
	var swimmer := _sum(&"wo.strong_swimmer", "Strong Swimmer", FALLS, 50.0, 10,
		"Fall in fifty times.")
	swimmer.secret = true
	made.append(swimmer)

	var wiped := _sum(&"wo.wiped_out", "Wiped Out", KNOCKS, 25.0, 10,
		"Be thrown by an obstacle twenty-five times.")
	wiped.secret = true
	made.append(wiped)

	var out := DotAchievementCatalogue.new()
	out.achievements = made
	return out


static func _sum(
	id: StringName, title: String, stat: StringName, target: float, points: int,
	description: String, series: StringName = &"", tier: int = 0
) -> DotAchievement:
	var out := DotAchievement.make(id, title, [
		DotAchievementRule.make(
			stat, target, DotAchievementRule.Op.AT_LEAST, DotAchievementRule.Merge.SUM
		),
	])
	out.description = description
	out.points = points
	out.series = series
	out.tier = tier
	return out


# --- Building ---------------------------------------------------------------

## [param directory] empty keeps achievement progress in memory; see
## [member WoConfig.progress_directory]. [param report] is [member WoConfig.report_progress].
func setup(directory: String, report: bool) -> DotResult:
	stats = DotStatsTracker.new()
	stats.name = "Stats"
	stats.schema = schema()
	stats.report_to_backbone = report
	stats.define_on_start = report
	add_child(stats)

	var counted := stats.start()

	if not counted.ok:
		return counted.wrap("wipeout stats")

	achievements = DotAchievementTracker.new()
	achievements.name = "Achievements"
	achievements.catalogue = catalogue()
	achievements.report_to_backbone = report
	# Not published: a server and a client in one process — every suite here — would fight
	# over one registry name, and the link below is handed the tracker directly.
	achievements.register_as = &""

	if directory != "":
		var file_store := DotAchievementStoreFile.new()
		file_store.directory = directory
		achievements.store = file_store
	else:
		achievements.store = DotAchievementStoreMemory.new()

	add_child(achievements)

	var awarded := achievements.start()

	if not awarded.ok:
		return awarded.wrap("wipeout achievements")

	achievements.unlocked.connect(_on_unlocked)

	link = DotAchievementStatsLink.new()
	link.name = "StatsLink"
	link.tracker = achievements
	link.stats = stats
	add_child(link)

	return link.start().wrap("wipeout's stats-to-achievements link")


# --- Counting ---------------------------------------------------------------

## Files one reading for one person, and starts counting for them the first time.
##
## [b]Begun lazily, on the first number, and that is what keeps stand-ins out.[/b] A player
## is added to the world before a bridge or a client marks them a stand-in, so a check at
## join time would see every bot as a person; by the time anything is worth counting, the
## flag is set. The memory and file stores load synchronously, so the achievement tracker
## has them before the reading that follows.
func record(player_id: StringName, stat: StringName, value: float = 1.0) -> void:
	if stats == null:
		return

	var body: WoPlayer = players.get(player_id)

	if body == null or body.is_bot:
		return

	var key := _key(player_id)

	if not stats.has_player(key):
		stats.begin(key, body.display_name)
		_begin(key)

	var filed := stats.record(key, stat, value)

	if not filed.ok:
		# WARN: a number a player earned that nobody will ever see. It is a schema or a key
		# that is wrong, and it only ever happens for a reason worth looking at.
		DotLog.warn(CHANNEL, "a reading was refused", {
			"player": String(player_id), "stat": String(stat), "why": filed.error.message,
		})


## The key a player's numbers are filed under. Asked of [member durable_key_fn] once, then
## remembered; see the class note.
func _key(player_id: StringName) -> StringName:
	if _keys.has(player_id):
		return _keys[player_id]

	var key := player_id

	if durable_key_fn.is_valid():
		var durable := str(durable_key_fn.call(player_id))

		if durable != "":
			key = StringName(durable)

	_keys[player_id] = key
	_ids[key] = player_id
	return key


## Loads somebody's lifetime progress. A statement call, never assigned: the tracker's
## `begin` is a coroutine, and this is the family's pattern for starting one from code that
## is not — `await` inside, a bare call outside.
func _begin(player_id: StringName) -> void:
	var began: DotResult = await achievements.begin(String(player_id))

	if not began.ok:
		# WARN: this player will earn nothing this session, and they will not be told why.
		DotLog.warn(CHANNEL, "achievement progress could not be loaded", {
			"player": String(player_id), "why": began.error.message,
		})


## Saves somebody's progress as they go. See [method _begin].
func _end(player_id: StringName) -> void:
	var ended: DotResult = await achievements.end(String(player_id))

	if not ended.ok:
		DotLog.warn(CHANNEL, "achievement progress could not be saved", {
			"player": String(player_id), "why": ended.error.message,
		})


## Stops counting for somebody who left, and saves what they earned.
func leave(player_id: StringName) -> void:
	_in_round.erase(player_id)
	_round_kills.erase(player_id)

	var key: StringName = _keys.get(player_id, player_id)
	_keys.erase(player_id)
	_ids.erase(key)

	if stats == null or not stats.has_player(key):
		return

	var _values := stats.end(key)
	link.forget(String(key))
	_end(key)


func session_values(player_id: StringName) -> DotStatsValues:
	return stats.session_values(_keys.get(player_id, player_id)) \
		if stats != null else DotStatsValues.new()


## The key [param player_id]'s numbers are filed under. For a console command and a suite.
func filed_under(player_id: StringName) -> StringName:
	return _keys.get(player_id, player_id)


# --- What the world reports -------------------------------------------------

func on_round_began() -> void:
	_in_round.clear()
	_round_kills.clear()
	_reached_finale = false

	for id: StringName in players:
		_in_round[id] = true


## The finishers are in an arena.
func on_handover() -> void:
	_reached_finale = true


## Somebody fell in on a course and was put back.
func on_fell(player_id: StringName) -> void:
	record(player_id, FALLS)


## An obstacle threw somebody. Counted where the knock is decided, which on a server is the
## player's own tick.
func on_knocked(player_id: StringName) -> void:
	record(player_id, KNOCKS)


## Somebody crossed the finish, [param place] first.
func on_finished(player_id: StringName, place: int, _seconds: float) -> void:
	record(player_id, COURSES_FINISHED)

	if place == 1:
		record(player_id, COURSES_FIRST)

	var body: WoPlayer = players.get(player_id)

	if body != null and body.falls == 0:
		record(player_id, CLEAN_RUNS)


## A round ended. [param winner] is a side, or 0 for a draw.
func on_round_over(winner: int) -> void:
	for id: StringName in _in_round.keys():
		var body: WoPlayer = players.get(id)

		if body == null:
			continue

		record(id, ROUNDS_PLAYED)

		var side := int(sides.get(id, 0))

		if winner > 0 and side == winner:
			record(id, ROUNDS_WON)

			if _reached_finale and body.is_alive() and not body.watching:
				record(id, FINALE_WINS)

		var kills := int(_round_kills.get(id, 0))

		if kills > 0:
			record(id, BEST_ROUND_KILLS, float(kills))

	_in_round.clear()
	_round_kills.clear()


## Somebody is out. [param by] is who did it, or empty for the world.
func on_died(player_id: StringName, by: StringName, _fell: bool, in_finale: bool) -> void:
	record(player_id, DEATHS)

	if by == &"" or by == player_id or not players.has(by):
		return

	if int(sides.get(by, 0)) == int(sides.get(player_id, 0)):
		return

	if in_finale:
		record(by, FINALE_KILLS)
		_round_kills[by] = int(_round_kills.get(by, 0)) + 1


func _on_unlocked(player: String, achievement: DotAchievement) -> void:
	# INFO: what an admin keeps. "I did the thing and was not told" is answered here.
	DotLog.info(CHANNEL, "an achievement was unlocked", {
		"player": player, "achievement": String(achievement.id), "points": achievement.points,
	})
	# Back to the world's id: the world tells the player, and the world knows them by that.
	earned.emit(_ids.get(StringName(player), StringName(player)),
		achievement.display_name, achievement.points)


func describe() -> Dictionary:
	return {
		"tracking": stats.players().size() if stats != null else 0,
		"in_round": _in_round.size(),
		"achievements": achievements.catalogue.size() if achievements != null else 0,
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()

	if stats != null:
		out.append_array(stats.describe_lines())

	if achievements != null:
		out.append_array(achievements.describe_lines())

	return out
