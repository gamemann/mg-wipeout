extends DotNetInput

const WoNetCommand := preload("wo_net_command.gd")

## One tick of a player's intent, on the wire: a movement command and a weapon slot.
##
## [b]The same command walks a player and flies a chopper, and that is this game's design
## rather than a saving.[/b] A pilot's jump is the collective, their strafe keys are the
## pedals and their forward key is the cyclic — nobody has to learn a second set of
## controls for a machine they might be in for thirty seconds — so there is one thing to
## send either way and the server decides which of the two it means. A client that sent
## "collective" would be telling the server it was flying.
##
## [b]The three game buttons ride in [member DotFpsCommand.buttons] for the reason a jump
## does:[/b] they are per-tick, they are held rather than pressed once, and they have to be
## ordered against the movement they were aimed with. A shot sent as a reliable request
## would arrive a round trip later and be resolved against a position the player has
## already left.
##
## The slot is the exception and is a field of its own, because [DotFpsCommand] has eight
## buttons and no room for a number — see [member WoPlayer.wanted_slot].

## Fire, and the chopper's drop. `BUTTON_USER_0`, which dot-player-controller reserves.
const BUTTON_FIRE := DotFpsCommand.BUTTON_USER_0

## The alt-fire, which on every blaster in the pack is a bash.
const BUTTON_ALT := DotFpsCommand.BUTTON_USER_1

const BUTTON_RELOAD := DotFpsCommand.BUTTON_USER_2

## How many bits the slot takes. Eight slots is one more than the pack uses.
const SLOT_BITS := 3

var move: DotFpsCommand = DotFpsCommand.new()

## Which weapon the player has asked for, or zero for "leave it alone".
var slot: int = 0

## Whether the grab key is held: pick up, or put down, what the player is looking at.
##
## [b]Here, in this game's own message, and not in [DotFpsCommand][/b], whose three spare
## buttons are fire, alt-fire and reload already. Widening the movement command would be a
## breaking change across every game in the family for a key only this one has. The server
## turns the held state into an edge; see `WoGame._advance_grabs`.
var grab: bool = false


func _write(writer: DotNetWriter) -> void:
	move.write(writer)
	writer.write_uint(clampi(slot, 0, (1 << SLOT_BITS) - 1), SLOT_BITS)
	writer.write_bool(grab)


func _read(reader: DotNetReader) -> void:
	move = DotFpsCommand.new()
	move.read(reader)
	slot = reader.read_uint(SLOT_BITS)
	grab = reader.read_bool()


## Not optional. Quantisation bounds each field; it cannot bound the relationship between
## them, and a move vector of (1, 1) is 41% more speed than anybody else — which in this
## game is 41% more load on the platform somebody else is standing on.
func _sanitise() -> void:
	move.sanitise()
	slot = clampi(slot, 0, (1 << SLOT_BITS) - 1)


func _equals(other: DotNetInput) -> bool:
	var them := other as WoNetCommand
	return them != null and slot == them.slot and grab == them.grab and move.equals(them.move)
