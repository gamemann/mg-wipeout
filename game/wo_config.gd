extends DotConfig

## Every number this game has, layered like every other [DotConfig] in the family.
##
## [code]exported defaults < JSON file < environment < command line[/code], identically to
## dot-server, dot-cloud and the other games. Nothing here reads
## [code]OS.get_cmdline_args[/code] itself.
##
## [b]Metres and seconds.[/b] The courses are documents in the same units (see
## [WoCourseDoc]), so a length a mapper writes and a length this file tunes against are the
## same number with no ratio between them.
##
## [b]What is NOT here is the courses.[/b] Where a platform is, how fast an arm turns and
## where the finish line stands are the course document's, because a course is content a
## server installs and a client is sent, not a setting an operator turns. This file is the
## rules every course is played under.

# --- The round -------------------------------------------------------------

@export_group("The round")

## Seconds everybody stands behind the start gate before it drops.
##
## [b]Not zero, and the reason is the join.[/b] Everybody is placed on the start pad in the
## same tick, and a course that started on that tick would be won by whoever's client had
## finished loading the course first.
@export_range(0.0, 30.0, 0.5) var countdown_seconds: float = 4.0

## Seconds the course is open before the round is called on the clock.
##
## A course document may ask for its own (`course_seconds` in the document) and this is the
## ceiling an operator puts on it, so a mapper cannot make a server run one course for an
## hour.
@export_range(10.0, 1200.0, 5.0) var course_seconds: float = 210.0

## Seconds between the course closing and the final death starting.
##
## [b]Not zero, for the teleport.[/b] Everybody who finished is moved into an arena they have
## never seen, and props and weapons arrive in the same instant; landing already being hit
## by a thrown barrel is a death nobody could have done anything about.
@export_range(0.0, 30.0, 0.5) var handover_seconds: float = 4.0

## Seconds the final death runs before the round is called on the clock (a draw).
@export_range(10.0, 900.0, 5.0) var finale_seconds: float = 100.0

## Seconds between rounds.
@export_range(0.0, 60.0, 1.0) var intermission_seconds: float = 8.0

## Seconds of warmup before the first round. 0 starts immediately.
@export_range(0.0, 300.0, 1.0) var warmup_seconds: float = 10.0

## Whether the side that got furthest wins a round nobody finished.
##
## [b]On, and the alternative is a draw nobody earned.[/b] A hard course on a server of four
## can close with nobody across the line; a draw then says the person who reached the last
## checkpoint and the person who never left the start pad played equally well.
@export var progress_decides: bool = true

# --- Sides -----------------------------------------------------------------

@export_group("Sides")

## How many teams the server plays with. 0 is every player for themselves.
##
## [b]Zero by default, and the course is why.[/b] An obstacle course is something one person
## runs; teams change what finishing means (a side is through if anybody on it is) and are a
## mode an operator chooses. Up to six, the same ceiling as mg-smash-copter for the same
## reason: beyond that the final death is a free-for-all with bookkeeping.
@export_range(0, 6, 1) var team_count: int = 0

## Whether players may pick their own side.
@export var allow_team_choice: bool = true

## Whether the server evens the sides up between rounds.
@export var autobalance: bool = true

# --- The players -----------------------------------------------------------

@export_group("The players")

@export_range(1.0, 400.0, 1.0) var player_health: float = 100.0

## How fast a player runs, in m/s.
@export_range(1.0, 20.0, 0.1) var run_speed: float = 7.0

## What fraction of [member run_speed] holding the walk key gives.
@export_range(0.1, 1.0, 0.01) var walk_speed_scale: float = 0.45

## Metres a standing jump rises.
@export_range(0.1, 5.0, 0.05) var jump_height: float = 1.25

## Metres per second squared, for everything: players and props.
##
## [b]Here rather than in `project.godot`, because a project setting does not travel with
## a delivered game.[/b] A pack mounted into the server tool's project runs at ITS setting,
## and what that looks like is a game that plays correctly on a developer's machine and
## floats everywhere it is deployed. Applied to the world's own physics space by [WoGame].
@export_range(1.0, 60.0, 0.5) var gravity: float = 20.0

## How hard an obstacle throws a player at the least, in m/s.
##
## [b]A floor under the knock, because a slow arm still has to move somebody.[/b] The knock
## is the surface's own speed where it touched them, and an arm turning at thirty degrees a
## second is a metre a second near its hub — which reads as an obstacle that does nothing.
@export_range(0.0, 40.0, 0.5) var knock_min_speed: float = 8.0

## The most an obstacle can throw a player, in m/s. A safety cap rather than a feel dial.
@export_range(1.0, 80.0, 0.5) var knock_max_speed: float = 22.0

## How far up every knock throws a player, in m/s.
##
## [b]Up as well as away, and the up is what makes it a wipeout.[/b] A knock along the
## ground is a shove a player can run out of; one that lifts them is a flight they watch.
@export_range(0.0, 30.0, 0.5) var knock_lift: float = 5.5

## Health a knock costs on the course, per m/s it threw the player. 0: knocks never hurt.
##
## [b]On by default since 2026-10-06[/b], because the brief asked for obstacles that hurt and
## some that are fatal: at 1.0 a slow arm (8 m/s) costs 8 and the hardest throw (22 m/s) 22.
## 1.4 was tried first and a stand-in took nine knocks before its first checkpoint, which
## at 1.4 was out of the round; a checkpoint heals.
@export_range(0.0, 10.0, 0.05) var knock_damage_per_speed: float = 1.0

## Whether a player whose health runs out on the course is out for the round (watching
## from the gallery) rather than put back at the last checkpoint. The brief's "fatal".
@export var course_deaths_eliminate: bool = true

## Whether crossing a checkpoint restores health, so one bad stretch is not a slow death.
@export var checkpoint_heals: bool = true

# --- Points -------------------------------------------------------------------

@export_group("Points")

## Points for finishing a course, by place: first, second, third... A finisher past the
## list gets [member finish_points_rest]. They add up over a match and show on the Tab board.
@export var finish_points: PackedInt32Array = PackedInt32Array([10, 7, 5])
@export_range(0, 100, 1) var finish_points_rest: int = 3

## Points for being on the side that wins the round, the final death included.
@export_range(0, 100, 1) var winner_points: int = 10

# --- Weather ------------------------------------------------------------------

@export_group("Weather")

## Chance, 0 to 1, that a round's course gets gusts of wind.
@export_range(0.0, 1.0, 0.05) var wind_chance: float = 0.5

## Strongest gust, as a sideways acceleration in m/s². Six is a stagger; twelve is a fall.
@export_range(0.0, 40.0, 0.5) var wind_strength: float = 7.0

## Chance, 0 to 1, that a round's course gets a thunderstorm: rain, and lightning striking
## the course at drawn places and moments.
@export_range(0.0, 1.0, 0.05) var storm_chance: float = 0.25

## How many lightning strikes a storm brings over a course.
@export_range(0, 60, 1) var storm_strikes: int = 14

## How near a strike knocks a player, in metres, and what it costs them.
@export_range(0.5, 20.0, 0.5) var strike_radius: float = 3.5
@export_range(0.0, 400.0, 1.0) var strike_damage: float = 35.0

# --- The courses -----------------------------------------------------------

@export_group("The courses")

## Which courses this server may play, by id. Empty means every one it has.
##
## [b]Ids, the shape mg-smash-copter's layout list has.[/b] An operator running one course
## all evening, or a render of one, is a word on a line rather than a code change.
## `--wo-course-ids=wo_spin_cycle` is how `tools/shot.sh` looks at one.
@export var course_ids: PackedStringArray = PackedStringArray()

## Whether the next course is drawn at random (seeded) rather than taken in order.
@export var shuffle_courses: bool = true

## Where course and arena documents are read from, beside the one built into this game.
##
## Relative to this game's own root, so a delivered pack reads its own copy. The directory
## is a link to the mg-wipeout-maps repository in a checkout (see `.gitignore`).
@export var course_directory: String = "courses"

## Seed every random choice in a round is drawn from: the course, the arena, the spawn
## areas, the drops.
##
## [b]A seed rather than a schedule, and reproducible on purpose.[/b] Two servers on one seed
## play the same round, which is what makes "the arena where the barrels all landed in the
## middle" a bug report somebody can act on.
@export var seed_value: int = 20261005

# --- The final death --------------------------------------------------------

@export_group("The final death")

## Which arenas this server may draw, by id. Empty means every one it has.
@export var arena_ids: PackedStringArray = PackedStringArray()

## How many props are dropped into an arena, per side that made it.
@export_range(0, 40, 1) var finale_props_per_side: int = 6

## How many weapons are laid out in an arena, per side that made it.
@export_range(0, 20, 1) var finale_weapons_per_side: int = 2

## The most props an arena holds at once, whatever the count above asks for.
@export_range(4, 200, 1) var prop_budget: int = 60

## Which weapons may be laid out, by id from the pack. Empty means a sensible default set.
@export var weapon_pool: PackedStringArray = PackedStringArray()

## How fast a thrown prop has to be going to hurt somebody, in m/s.
@export_range(0.5, 60.0, 0.5) var throw_hurt_speed: float = 7.0

## Damage a thrown prop does, per kilogram metre per second of momentum.
@export_range(0.0, 2.0, 0.005) var throw_damage_per_impulse: float = 0.075

## How hard a thrown prop leaves the hands, as an impulse.
@export_range(10.0, 20000.0, 10.0) var throw_impulse: float = 1500.0

# --- Bots ------------------------------------------------------------------

@export_group("Bots")

## How many players the server keeps in the round by adding stand-ins.
##
## [b]Two by default, so one person on an empty server has somebody to beat.[/b] The course
## needs nobody else, but a final death needs two finishers.
@export_range(0, 24, 1) var minimum_players: int = 3

## How far a stand-in's aim is off, in degrees, drawn once per bot per round.
@export_range(0.0, 45.0, 0.5) var bot_aim_spread_degrees: float = 7.0

## How likely a stand-in is to mistime a jump, in a hundred.
##
## [b]Not zero, and an empty server is why.[/b] A bot that never falls finishes every course
## in the same time, every round; one that misses one jump in eight looks like a person and
## gives a real person something to beat.
@export_range(0.0, 100.0, 1.0) var bot_fumble_chance: float = 12.0

# --- Watching --------------------------------------------------------------

@export_group("Watching")

## Who somebody who is out may watch: 0 anybody, 1 their own side, 2 nobody.
@export_enum("anybody", "own side", "nobody") var spectate_camera: int = 0

# --- Progress --------------------------------------------------------------

@export_group("Progress")

## Whether the server counts per-player numbers and awards achievements at all.
@export var keep_progress: bool = true

## Where lifetime achievement progress is written. Empty keeps it in memory.
@export var progress_directory: String = ""

## Whether the numbers and the unlocks are reported to the backbone. Needs a credential.
@export var report_progress: bool = false


func env_prefix() -> String:
	return "WO_"


func cli_prefix() -> String:
	return "--wo-"


## Whether this server plays in teams.
func teams() -> bool:
	return team_count >= 2


func validate() -> DotResult:
	if course_seconds <= 0.0 or finale_seconds <= 0.0:
		return DotResult.fail(
			DotError.CODE_INVALID, "Both halves of a round have to last some time."
		)

	# One team is not a mode: it is everybody on the same side with nobody to beat, and the
	# final death would end on its first tick.
	if team_count == 1 or team_count > 6:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"team_count is %d; this game plays solo (0) or with two to six sides." % team_count,
		)

	if knock_max_speed < knock_min_speed:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"knock_max_speed (%.1f) is below knock_min_speed (%.1f)."
				% [knock_max_speed, knock_min_speed],
		)

	if spectate_camera < 0 or spectate_camera > 2:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"spectate_camera is %d; it is 0 (anybody), 1 (own side) or 2 (nobody)."
				% spectate_camera,
		)

	return DotResult.success(null)


func describe() -> Dictionary:
	return {
		"sides": "%d teams" % team_count if teams() else "solo",
		"course": "%.0f s" % course_seconds,
		"finale": "%.0f s" % finale_seconds,
		"courses": "all" if course_ids.is_empty() else ",".join(course_ids),
		"arenas": "all" if arena_ids.is_empty() else ",".join(arena_ids),
		"gravity": "%.1f m/s2" % gravity,
		"bots": minimum_players,
	}


## Overridden to print what this game is tuned to rather than every field.
##
## The signature carries the parent's `redact_sensitive` even though nothing here is a
## secret: a subclass that quietly narrows an override is a method that is silently the
## parent's at every call site that passes the argument.
func describe_lines(_redact_sensitive: bool = true) -> PackedStringArray:
	var lines := PackedStringArray()
	lines.append("wipeout configuration")
	var facts := describe()
	for key: String in facts:
		lines.append("  %-14s %s" % [key, facts[key]])
	return lines
