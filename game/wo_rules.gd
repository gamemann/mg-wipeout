extends DotMatchRules

## A round ends when the game says so, and the game says who won.
##
## [b]Neither of dot-match's two shipped shapes fits, and that is not a gap in dot-match.[/b]
## A round here is a course that ends when everybody is across or the clock runs out, then —
## only if two sides finished — a final death that ends on the last side standing. Nobody
## dies on a course, so an elimination rule would never fire; nobody scores, so a score rule
## would never fire either. What decides is [WoGame], which knows who finished, in what order,
## and who is still up in the arena — and [DotMatchRules] is documented as the place a mode
## dot-match does not ship goes, with the state machine left alone.
##
## [b]The answer is read, never computed here.[/b] dot-match's rules are meant to be pure
## functions of what they are handed; this one is a pure function of what the game decided,
## and a game that has not decided returns NONE every tick.

## `func() -> Dictionary`: `{decided: bool, winner: int}`. Set by [WoGame].
var decision_fn: Callable = Callable()


static func make() -> DotMatchRules:
	# Not this class's own name, for dot-match's reason: a script that names itself in an
	# expression cuts Godot 4.7.2's exit teardown short. See docs/gdscript-hazards.md.
	var rules := new()
	rules.id = &"wipeout"
	rules.display_name = "Wipeout"
	rules.score_limit = 0
	# The course and the final death keep their own clocks; this one is the BACKSTOP, set by
	# [WoGame] to their sum and a minute more. A round the game somehow never decided — a
	# rule with a hole in it — ends on it as a draw rather than running for ever, and dot-match
	# stops warning at every boot that nothing but a custom outcome can end a round.
	rules.time_limit_sec = 600.0
	rules.rounds_to_win = 999
	rules.respawn_disabled = true
	rules.kill_points = 1
	rules.suicide_points = 0
	return rules


func _round_outcome(
	_scoreboard: DotScoreboard,
	_teams: DotTeamManager,
	_elapsed_sec: float
) -> Outcome:
	if not decision_fn.is_valid():
		return Outcome.NONE

	var decision: Dictionary = decision_fn.call()

	if bool(decision.get("decided", false)):
		return Outcome.CUSTOM

	# Only the backstop clock is left to the parent: there is no score limit to reach.
	return super._round_outcome(_scoreboard, _teams, _elapsed_sec)


func _round_winner(_scoreboard: DotScoreboard, _teams: DotTeamManager) -> int:
	if not decision_fn.is_valid():
		return 0

	return int((decision_fn.call() as Dictionary).get("winner", 0))
