extends DotFpsController

## The first-person controller, with the two hooks a course needs inside the tick.
##
## [b]Inside the tick, and outside it is wrong in a way only a connected client shows.[/b]
## dot-net's predictor re-simulates past ticks when a snapshot corrects the client, and it
## does that by calling `simulate_tick` directly — so anything a game does "around" the tick
## in its own loop is skipped on every replayed one. A replay that did not pose the obstacles
## at the tick being replayed would sweep the player against arms where they are NOW, several
## ticks later, and every correction would correct into a different answer. dot-player-
## controller documents [method _on_pre_simulate] and [method _on_post_simulate] as running
## during replays for exactly this, and this subclass is the whole of using them.

## `func(tick: int) -> void`: put the world where it is on [param tick], before the motor runs.
var before_fn: Callable = Callable()

## `func(tick: int, state: DotFpsState) -> void`: what the world does to the player after
## the motor has moved them — a carry, a knock, a bounce.
var after_fn: Callable = Callable()


func _on_pre_simulate(tick: int, _delta: float) -> void:
	if before_fn.is_valid():
		before_fn.call(tick)


func _on_post_simulate(tick: int, _delta: float) -> void:
	if after_fn.is_valid():
		after_fn.call(tick, state)
