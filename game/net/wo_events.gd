extends RefCounted

const WoGame := preload("../wo_game.gd")

## The wire format for everything that is not a snapshot or an input.
##
## Encoders and decoders in pairs, and nothing checks that they are inverses for you —
## `headless_net` round-trips every one of them, because this family has already shipped a
## serialisation whose two ends never met: dot-moderation wrote `"voice muted"` and read
## back a warning, and the one thing that addon existed for silently did nothing.
##
## [b]The course is a document, and it travels whole.[/b] `STAGE` carries the normalised
## document a server built (see [WoCourseDoc]), deflated: a client builds the identical course
## from it and needs no course files of its own. Nothing on a course is replicated after that,
## because every obstacle is a function of the tick (see [WoCourse]); what a snapshot carries
## is players and props.

enum Kind {
	## Who you are, how fast the server ticks, and how long each part of a round is.
	HELLO,
	## The course or the arena, as a document. Build it from this.
	STAGE,
	## A player is in the world: net id, name, side, face.
	JOIN,
	LEAVE,
	## A player changed sides.
	TEAM,
	## A prop now exists, what it is, and which net id moves it.
	PROP,
	## A prop is gone.
	PROP_GONE,
	## The round clock and the numbers a client cannot count for itself.
	CLOCK,
	## A round began or ended, and who won.
	ROUND,
	## The round moved on: countdown, course, handover, final death.
	PHASE,
	## Somebody is out of the final death, and what did it.
	DEATH,
	## A barrel went off.
	BLAST,
	## Somebody was given, or picked up, a weapon.
	ARMED,
	## Text for one player.
	NOTICE,
	## One routed chat line.
	CHAT,
	## What this one player's camera is on now that they are out. To its owner only.
	SPECTATE,
	## Somebody fell in, crossed a checkpoint, or finished. What the HUD and the feed say.
	PROGRESS,
	## A weapon is lying in the arena.
	PICKUP,
	## A weapon was picked up, or cleared away.
	PICKUP_GONE,
}

enum Ask {
	## I have built my world and can receive. Tell me everything in it.
	READY,
	## I typed a line. The server decides what channel it lands on and who hears it.
	SAY,
	## Put me on that side.
	TEAM,
	## I am out: show me the next person, the previous one, or the other camera.
	SPECTATE,
}

## What a `PROGRESS` event says happened.
enum Progress {
	FELL,
	CHECKPOINT,
	FINISHED,
}

## Every decoder returns an `ok` beside its fields, and every caller checks it.
##
## [b]A reader past its end returns plausible zeros rather than failing.[/b] dot-net shipped
## with exhaustion that was not sticky, so a decoder that skipped this check got a
## believable value for the field AFTER the overrun — and a truncated packet decodes as a
## valid message about nothing.
const NAME_BYTES := 64
const ID_BYTES := 64
const TEXT_BYTES := 256

## The largest stage a reader accepts: [WoCourseDoc.WIRE_LIMIT] and its header.
const STAGE_BYTES := 65536 + 16

## The most an avatar document may take in a JOIN. One slot is about eighty bytes; the rest
## is room for slots this game does not have yet, and a cap that a hostile document cannot
## talk its way past.
const AVATAR_BYTES := 1024

## Where a body may be, in metres, on the wire.
##
## [b]Read from [WoGame], not written here.[/b] A quantised position is decoded against this
## range, so two files holding two numbers do not lose precision — they put the thing
## somewhere else. game-arena had exactly this, 256 against 128, in two files that each
## looked right on its own.
const WORLD_EXTENT := WoGame.NET_WORLD_EXTENT
const POS_BITS := 24

## The round clock, in seconds. Well past anything the configuration allows, because the
## extra bit is cheaper than the bug of a clock that wraps.
const CLOCK_MAX := 1800.0
const CLOCK_BITS := 15

## A team COUNT is 0..6, so three bits. A side itself is a varint wherever it is sent: with
## no teams a side is a player's own, numbered from 100.
const TEAM_BITS := 3

## Phases, three bits: five of them and room for three more.
const PHASE_BITS := 3


static func kind_name(kind: int) -> String:
	var names := Kind.keys()
	return String(names[kind]) if kind >= 0 and kind < names.size() else "?"


static func ask_name(ask: int) -> String:
	var names := Ask.keys()
	return String(names[ask]) if ask >= 0 and ask < names.size() else "?"


static func _w() -> DotNetWriter:
	return DotNetWriter.new()


# --- Hello -----------------------------------------------------------------

static func write_hello(
	player_id: int,
	tick_rate: int,
	server_tick: int,
	team_count: int,
	countdown_seconds: float,
	course_seconds: float,
	handover_seconds: float,
	finale_seconds: float
) -> PackedByteArray:
	var w := _w()
	w.write_varint(player_id)
	w.write_uint(tick_rate, 9)
	w.write_varint(server_tick)
	w.write_uint(clampi(team_count, 0, 7), TEAM_BITS)
	# Fourteen bits over two minutes is seven milliseconds: the countdown is shown to the tenth
	# and a client's must end on the server's tick, not a tenth of a second either side.
	w.write_float_range(countdown_seconds, 0.0, 120.0, 14)
	w.write_float_range(course_seconds, 0.0, CLOCK_MAX, CLOCK_BITS)
	w.write_float_range(handover_seconds, 0.0, 120.0, 14)
	w.write_float_range(finale_seconds, 0.0, CLOCK_MAX, CLOCK_BITS)
	return w.to_bytes()


static func read_hello(r: DotNetReader) -> Dictionary:
	var player_id := r.read_varint()
	var tick_rate := r.read_uint(9)
	var server_tick := r.read_varint()
	var team_count := r.read_uint(TEAM_BITS)
	var countdown := r.read_float_range(0.0, 120.0, 14)
	var course := r.read_float_range(0.0, CLOCK_MAX, CLOCK_BITS)
	var handover := r.read_float_range(0.0, 120.0, 14)
	var finale := r.read_float_range(0.0, CLOCK_MAX, CLOCK_BITS)
	return {
		"player_id": player_id,
		"tick_rate": tick_rate,
		"server_tick": server_tick,
		"team_count": team_count,
		"countdown_seconds": countdown,
		"course_seconds": course,
		"handover_seconds": handover,
		"finale_seconds": finale,
		"ok": r.ok(),
	}


# --- The stage --------------------------------------------------------------

## The course or the arena: [WoCourseDoc.encode]'s bytes, as they are.
##
## [b]Opaque here, and checked at the other end.[/b] The client decodes and VALIDATES what it
## is sent, so a document this build cannot read is refused with a sentence rather than half
## built; this layer only has to carry bytes without cutting them.
static func write_stage(encoded: PackedByteArray) -> PackedByteArray:
	var w := _w()
	w.write_bytes(encoded)
	return w.to_bytes()


static func read_stage(r: DotNetReader) -> Dictionary:
	var encoded := r.read_bytes(STAGE_BYTES)
	return {"encoded": encoded, "ok": r.ok() and not encoded.is_empty()}


# --- Players ---------------------------------------------------------------

## A join, or a change to who somebody is: their name, their side, their avatar.
##
## [b]The avatar is the document, not the skin it picks[/b] — as JSON, capped at
## [constant AVATAR_BYTES], and empty for the stock person. A skin index would be smaller,
## and would make every client's reading of a document the server's, so a slot this game
## adds later would need a new wire. [b]Appended, never inserted[/b]: a field before it
## would move the team for every reader of the old layout.
static func write_join(
	player_id: int, net_id: int, display_name: String, team: int,
	avatar: DotAvatar = null
) -> PackedByteArray:
	var w := _w()
	w.write_varint(player_id)
	w.write_varint(net_id)
	w.write_string(display_name, NAME_BYTES)
	w.write_varint(maxi(team, 0))
	w.write_string(JSON.stringify(avatar.to_dict()) if avatar != null else "", AVATAR_BYTES)
	return w.to_bytes()


static func read_join(r: DotNetReader) -> Dictionary:
	var player_id := r.read_varint()
	var net_id := r.read_varint()
	var display_name := r.read_string(NAME_BYTES)
	var team := r.read_varint()
	var text := r.read_string(AVATAR_BYTES)
	var avatar: DotAvatar = null

	# A document that does not parse is the stock person, not a refused join: an avatar is
	# cosmetic, and somebody who cannot be drawn as themselves can still be drawn.
	if text != "":
		var parsed: Variant = JSON.parse_string(text)

		if parsed is Dictionary:
			var built := DotAvatar.from_dict(parsed)

			if built.ok:
				avatar = built.value

	return {
		"player_id": player_id,
		"net_id": net_id,
		"name": display_name,
		"team": team,
		"avatar": avatar,
		"ok": r.ok(),
	}


static func write_player(player_id: int) -> PackedByteArray:
	var w := _w()
	w.write_varint(player_id)
	return w.to_bytes()


static func read_player(r: DotNetReader) -> int:
	return r.read_varint()


static func write_team(player_id: int, team: int) -> PackedByteArray:
	var w := _w()
	w.write_varint(player_id)
	w.write_varint(maxi(team, 0))
	return w.to_bytes()


static func read_team(r: DotNetReader) -> Dictionary:
	var player_id := r.read_varint()
	var team := r.read_varint()
	return {"player_id": player_id, "team": team, "ok": r.ok()}


static func write_death(player_id: int, by: int, why: StringName) -> PackedByteArray:
	var w := _w()
	w.write_varint(player_id)
	w.write_varint(by)
	w.write_string(String(why), ID_BYTES)
	return w.to_bytes()


static func read_death(r: DotNetReader) -> Dictionary:
	var player_id := r.read_varint()
	var by := r.read_varint()
	var why := r.read_string(ID_BYTES)
	return {"player_id": player_id, "by": by, "why": StringName(why), "ok": r.ok()}


## What a survivor was handed, so a watcher's HUD can name it.
static func write_armed(player_id: int, weapon_id: StringName) -> PackedByteArray:
	var w := _w()
	w.write_varint(player_id)
	w.write_string(String(weapon_id), ID_BYTES)
	return w.to_bytes()


static func read_armed(r: DotNetReader) -> Dictionary:
	var player_id := r.read_varint()
	var weapon_id := r.read_string(ID_BYTES)
	return {"player_id": player_id, "weapon_id": StringName(weapon_id), "ok": r.ok()}


# --- What is in the world --------------------------------------------------

## Something the world has put out: a prop. [param vehicle] is always false in this game;
## the bit stays so the encoder is mg-smash-copter's, which already has both ends checked.
static func write_prop(
	net_id: int, kind_id: StringName, at: Vector3, vehicle: bool
) -> PackedByteArray:
	var w := _w()
	w.write_varint(net_id)
	w.write_string(String(kind_id), ID_BYTES)
	w.write_vector3_range(at, -WORLD_EXTENT, WORLD_EXTENT, POS_BITS)
	w.write_bool(vehicle)
	return w.to_bytes()


static func read_prop(r: DotNetReader) -> Dictionary:
	var net_id := r.read_varint()
	var kind_id := r.read_string(ID_BYTES)
	var at := r.read_vector3_range(-WORLD_EXTENT, WORLD_EXTENT, POS_BITS)
	var vehicle := r.read_bool()
	return {
		"net_id": net_id,
		"kind_id": StringName(kind_id),
		"position": at,
		"vehicle": vehicle,
		"ok": r.ok(),
	}


static func write_prop_gone(net_id: int, reason: StringName) -> PackedByteArray:
	var w := _w()
	w.write_varint(net_id)
	w.write_string(String(reason), ID_BYTES)
	return w.to_bytes()


static func read_prop_gone(r: DotNetReader) -> Dictionary:
	var net_id := r.read_varint()
	var reason := r.read_string(ID_BYTES)
	return {"net_id": net_id, "reason": StringName(reason), "ok": r.ok()}


# --- The round -------------------------------------------------------------

## The clock, and the numbers a client cannot count for itself.
##
## [b]`course_elapsed` is a finish time's zero.[/b] A client shows a running course time, and
## the phase's own clock restarts at every phase; the two are different numbers.
static func write_clock(
	round_number: int,
	elapsed: float,
	course_elapsed: float,
	phase: int,
	finished: int,
	alive: int,
	playable: bool
) -> PackedByteArray:
	var w := _w()
	w.write_varint(round_number)
	w.write_float_range(clampf(elapsed, 0.0, CLOCK_MAX), 0.0, CLOCK_MAX, CLOCK_BITS)
	w.write_float_range(clampf(course_elapsed, 0.0, CLOCK_MAX), 0.0, CLOCK_MAX, CLOCK_BITS)
	w.write_uint(clampi(phase, 0, 7), PHASE_BITS)
	w.write_uint(clampi(finished, 0, 255), 8)
	w.write_uint(clampi(alive, 0, 255), 8)
	w.write_bool(playable)
	return w.to_bytes()


static func read_clock(r: DotNetReader) -> Dictionary:
	var round_number := r.read_varint()
	var elapsed := r.read_float_range(0.0, CLOCK_MAX, CLOCK_BITS)
	var course_elapsed := r.read_float_range(0.0, CLOCK_MAX, CLOCK_BITS)
	var phase := r.read_uint(PHASE_BITS)
	var finished := r.read_uint(8)
	var alive := r.read_uint(8)
	var playable := r.read_bool()
	return {
		"round": round_number,
		"elapsed": elapsed,
		"course_elapsed": course_elapsed,
		"phase": phase,
		"finished": finished,
		"alive": alive,
		"playable": playable,
		"ok": r.ok(),
	}


## A round began or ended. [param winner] is a side — with no teams a side is a player's own
## and numbered from 100, so it is a varint and not three bits — and [param why] the sentence
## the server decided it with, which is what the HUD prints.
static func write_round(number: int, began: bool, winner: int, why: String = "") -> PackedByteArray:
	var w := _w()
	w.write_varint(number)
	w.write_bool(began)
	w.write_varint(maxi(winner, 0))
	w.write_string(why, TEXT_BYTES)
	return w.to_bytes()


static func read_round(r: DotNetReader) -> Dictionary:
	var number := r.read_varint()
	var began := r.read_bool()
	var winner := r.read_varint()
	var why := r.read_string(TEXT_BYTES)
	return {"round": number, "began": began, "winner": winner, "why": why, "ok": r.ok()}


static func write_phase(phase: int) -> PackedByteArray:
	var w := _w()
	w.write_uint(clampi(phase, 0, 7), PHASE_BITS)
	return w.to_bytes()


static func read_phase(r: DotNetReader) -> Dictionary:
	var phase := r.read_uint(PHASE_BITS)
	return {"phase": phase, "ok": r.ok()}


static func write_blast(at: Vector3, radius: float) -> PackedByteArray:
	var w := _w()
	w.write_vector3_range(at, -WORLD_EXTENT, WORLD_EXTENT, POS_BITS)
	w.write_float_range(radius, 0.0, 64.0, 12)
	return w.to_bytes()


static func read_blast(r: DotNetReader) -> Dictionary:
	var at := r.read_vector3_range(-WORLD_EXTENT, WORLD_EXTENT, POS_BITS)
	var radius := r.read_float_range(0.0, 64.0, 12)
	return {"position": at, "radius": radius, "ok": r.ok()}


# --- Watching --------------------------------------------------------------

## A view dot-spectate decided, for the one player it belongs to.
##
## [b]The death position travels.[/b] `DotSpectatorView.to_wire` did not carry it until
## 2026-09-25, and a mirror without it puts every death camera at the world origin, which
## in this map is inside the cannon. This event stays the game's own: bit-packed and keyed
## by session, where dot-spectate's is a dictionary keyed by string. Everything else a mirror needs to
## draw the camera it already has: the players are in its world.
##
## Sessions rather than keys, as everywhere on this wire; zero is nobody.
static func write_spectate(
	viewer: int, mode: int, target: int, killer: int, death_at: Vector3
) -> PackedByteArray:
	var w := _w()
	w.write_varint(viewer)
	w.write_uint(clampi(mode, 0, 7), 3)
	w.write_varint(maxi(target, 0))
	w.write_varint(maxi(killer, 0))
	w.write_vector3_range(death_at, -WORLD_EXTENT, WORLD_EXTENT, POS_BITS)
	return w.to_bytes()


static func read_spectate(r: DotNetReader) -> Dictionary:
	var viewer := r.read_varint()
	var mode := r.read_uint(3)
	var target := r.read_varint()
	var killer := r.read_varint()
	var death_at := r.read_vector3_range(-WORLD_EXTENT, WORLD_EXTENT, POS_BITS)
	return {
		"viewer": viewer, "mode": mode, "target": target, "killer": killer,
		"death_at": death_at, "ok": r.ok(),
	}


## Next (+1), previous (-1), or the other camera (0).
static func write_ask_spectate(direction: int) -> PackedByteArray:
	var w := _w()
	w.write_uint(clampi(direction, -1, 1) + 1, 2)
	return w.to_bytes()


static func read_ask_spectate(r: DotNetReader) -> Dictionary:
	var raw := r.read_uint(2)
	return {"direction": clampi(raw, 0, 2) - 1, "ok": r.ok()}


static func write_ask_team(team: int) -> PackedByteArray:
	var w := _w()
	w.write_uint(clampi(team, 0, 7), TEAM_BITS)
	return w.to_bytes()


static func read_ask_team(r: DotNetReader) -> Dictionary:
	var team := r.read_uint(TEAM_BITS)
	return {"team": team, "ok": r.ok()}


# --- The course ------------------------------------------------------------

## Somebody fell in, crossed checkpoint [param value], or finished in place [param value]
## after [param seconds]. See [enum Progress].
static func write_progress(player_id: int, kind: int, value: int, seconds: float) -> PackedByteArray:
	var w := _w()
	w.write_varint(player_id)
	w.write_uint(clampi(kind, 0, 3), 2)
	w.write_varint(maxi(value, 0))
	w.write_float_range(clampf(seconds, 0.0, CLOCK_MAX), 0.0, CLOCK_MAX, 20)
	return w.to_bytes()


static func read_progress(r: DotNetReader) -> Dictionary:
	var player_id := r.read_varint()
	var kind := r.read_uint(2)
	var value := r.read_varint()
	var seconds := r.read_float_range(0.0, CLOCK_MAX, 20)
	return {"player_id": player_id, "kind": kind, "value": value, "seconds": seconds, "ok": r.ok()}


# --- The final death --------------------------------------------------------

static func write_pickup(pickup_id: int, weapon_id: StringName, at: Vector3) -> PackedByteArray:
	var w := _w()
	w.write_varint(pickup_id)
	w.write_string(String(weapon_id), ID_BYTES)
	w.write_vector3_range(at, -WORLD_EXTENT, WORLD_EXTENT, POS_BITS)
	return w.to_bytes()


static func read_pickup(r: DotNetReader) -> Dictionary:
	var pickup_id := r.read_varint()
	var weapon_id := r.read_string(ID_BYTES)
	var at := r.read_vector3_range(-WORLD_EXTENT, WORLD_EXTENT, POS_BITS)
	return {"pickup_id": pickup_id, "weapon_id": StringName(weapon_id), "position": at, "ok": r.ok()}


## A weapon off the floor, by [param by] (a session), or 0 when the arena was cleared.
static func write_pickup_gone(pickup_id: int, by: int) -> PackedByteArray:
	var w := _w()
	w.write_varint(pickup_id)
	w.write_varint(maxi(by, 0))
	return w.to_bytes()


static func read_pickup_gone(r: DotNetReader) -> Dictionary:
	var pickup_id := r.read_varint()
	var by := r.read_varint()
	return {"pickup_id": pickup_id, "by": by, "ok": r.ok()}


# --- Chat ------------------------------------------------------------------

## A chat line's own field widths. Wider than the rules allow, so a rule can be raised
## without the wire silently truncating what it lets through.
const CHAT_BYTES := 200
const CHAT_CHANNEL_BYTES := 24
const CHAT_KEY_BYTES := 48
const CHAT_KIND_BITS := 4


## One routed line, in [DotChatMessage]'s own wire shape.
##
## [b]Field by field rather than `var_to_bytes`, like every other message here.[/b] A
## dictionary serialised whole is a dictionary whose contents are whatever the sender put
## in it — including keys a client will happily read — and the widths below are the
## validation. `x.p` is the one meta field this game carries: the speaker's session id, so
## a client can colour a line by whose it is.
static func write_chat(wire: Dictionary) -> PackedByteArray:
	var w := _w()
	w.write_varint(int(wire.get("n", 0)))
	w.write_uint(int(wire.get("t", 0)), 32)
	w.write_string(str(wire.get("c", "")), CHAT_CHANNEL_BYTES)
	w.write_uint(
		maxi(0, DotChatMessage.kind_from_name(str(wire.get("k", "say")))), CHAT_KIND_BITS
	)
	w.write_string(str(wire.get("s", "")), CHAT_KEY_BYTES)
	w.write_string(str(wire.get("d", "")), NAME_BYTES)
	w.write_string(str(wire.get("w", "")), CHAT_KEY_BYTES)
	w.write_string(str(wire.get("m", "")), CHAT_BYTES)

	var meta: Variant = wire.get("x")
	var player_id := 0

	if typeof(meta) == TYPE_DICTIONARY:
		player_id = int((meta as Dictionary).get("p", 0))

	w.write_varint(maxi(player_id, 0))
	return w.to_bytes()


static func read_chat(r: DotNetReader) -> Dictionary:
	var out := {
		"n": r.read_varint(),
		"t": r.read_uint(32),
		"c": r.read_string(CHAT_CHANNEL_BYTES),
	}

	var kind := r.read_uint(CHAT_KIND_BITS)
	out["k"] = (
		DotChatMessage.KIND_NAMES[kind] if kind >= 0 and kind < DotChatMessage.KIND_NAMES.size()
		else "say"
	)

	out["s"] = r.read_string(CHAT_KEY_BYTES)
	out["d"] = r.read_string(NAME_BYTES)
	out["w"] = r.read_string(CHAT_KEY_BYTES)
	out["m"] = r.read_string(CHAT_BYTES)

	var player_id := r.read_varint()

	if player_id > 0:
		out["x"] = {"p": player_id}

	out["ok"] = r.ok()
	return out


## What a client sends when somebody presses Enter: a channel and a line, and nothing else.
##
## [b]No speaker, no time, no colour.[/b] Everything about what a line MEANS is decided on
## the server — who said it, whether they are gagged, whether they are talking too fast,
## which channel they may use and who can hear it. A client that sent any of that would be
## a client that could claim it.
static func write_say(channel_id: StringName, text: String) -> PackedByteArray:
	var w := _w()
	w.write_string(String(channel_id), CHAT_CHANNEL_BYTES)
	w.write_string(text, CHAT_BYTES)
	return w.to_bytes()


static func read_say(r: DotNetReader) -> Dictionary:
	var out := {
		"channel": r.read_string(CHAT_CHANNEL_BYTES),
		"text": r.read_string(CHAT_BYTES),
	}
	out["ok"] = r.ok()
	return out


static func write_notice(text: String) -> PackedByteArray:
	var w := _w()
	w.write_string(text, TEXT_BYTES)
	return w.to_bytes()


static func read_notice(r: DotNetReader) -> Dictionary:
	var text := r.read_string(TEXT_BYTES)
	return {"text": text, "ok": r.ok()}
