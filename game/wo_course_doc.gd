extends RefCounted

## What a course and an arena ARE: a JSON document, checked here before anything is built.
##
## [b]A course is a document, not a scene, and that is the decision every other file in this
## game leans on.[/b] A scene per course would be content to import, to rebase inside a
## mounted pack and to keep in step across a server and every client; a document is a few
## kilobytes the server reads off disk and SENDS to each client at the top of a round. So a
## client needs no course files at all, a server can be given a new course by dropping a file
## in a directory, and the two ends cannot disagree about where a platform is, because there
## is only one copy and it travelled. mg-smash-copter decided the same about its platform
## field ("the cell list travels rather than the layout id alone") and for the same reason.
##
## [b]Two kinds of document.[/b] A `course` is what everybody runs: a start pad, pieces,
## checkpoints, a finish. An `arena` is where a final death is fought: pieces, the areas a
## side can be put down in, where props and weapons arrive, and a gallery for everybody who
## did not finish. Both are built by [WoCourse] from the same piece vocabulary, so a spinning
## arm in an arena is the same arm a course has.
##
## [b]Validated, and a refused document is a line in the log, not a broken round.[/b] The
## catalogue loads everything it can and skips what this refuses, saying why; a server with
## one bad file plays the other nine.
##
## Every length is metres, every angle degrees, every time seconds. A position is the CENTRE
## of what it places unless the field's own comment says otherwise. The mg-wipeout-maps
## repository's README is the mapper's copy of this, with an example of every kind.

const CHANNEL := "wo.doc"

## The format this build reads. A document written for a later one is refused rather than
## half-built, because a piece kind this build has never heard of is a hole in the course.
const FORMAT := 1

const KIND_COURSE := "course"
const KIND_ARENA := "arena"

## The largest a document may be on the wire, compressed, in bytes.
##
## [b]A cap because a reliable event is retransmitted until it arrives.[/b] A megabyte of
## pieces would be a stall for every client at every round start; sixty-four kilobytes is
## several hundred pieces, past anything a course needs.
const WIRE_LIMIT := 65536

## The most pieces one document may hold.
const MAX_PIECES := 600

## Every piece kind, and the fields each one must have.
##
## [b]A table rather than a branch per kind,[/b] so the mapper's README, the validator and
## the builder can be checked against one list. The meaning of each is in [WoCourse], where
## it is built.
const PIECES := {
	# Still things.
	"box": ["at", "size"],
	"ramp": ["at", "size", "pitch"],
	"ball": ["at", "radius"],
	"cylinder": ["at", "radius", "height"],
	# Things that move, and carry whoever is standing on them.
	"mover": ["from", "to", "size", "period"],
	"turntable": ["at", "radius", "speed"],
	"roller": ["at", "length", "radius", "speed"],
	"seesaw": ["at", "size", "amplitude", "period"],
	"tiles": ["at", "cols", "rows", "tile", "period", "down"],
	"conveyor": ["at", "size", "speed"],
	"bouncer": ["at", "size", "power"],
	# Things that move, and throw whoever they touch.
	"spinner": ["at", "arm_length", "speed"],
	"pendulum": ["pivot", "length", "radius", "swing", "period"],
	"pusher": ["at", "size", "reach", "period"],
}

## The roles a surface can be drawn as. See [WoTextures.Role].
const ROLES := ["deck", "pillar", "cannon", "arena", "hazard", "safe"]


## Reads a document from JSON text, and checks it.
static func parse_json(text: String, origin: String = "") -> DotResult:
	var json := JSON.new()
	var parsed := json.parse(text)

	if parsed != OK:
		return DotResult.fail(
			DotError.CODE_PARSE,
			"The document is not JSON.",
			"%s line %d: %s" % [origin, json.get_error_line(), json.get_error_message()]
		)

	if typeof(json.data) != TYPE_DICTIONARY:
		return DotResult.fail(DotError.CODE_PARSE, "The document is not a JSON object.", origin)

	return validate(json.data as Dictionary)


## Checks a document and returns a normalised copy of it: every optional field present, every
## number a float, every position three of them.
##
## [b]A copy, so the builder never sees what a mapper wrote.[/b] It sees what this said the
## mapper meant — which is the one version a client is also sent — so a missing `yaw` is 0.0
## on both ends rather than "absent" on one and "0" on the other.
static func validate(source: Dictionary) -> DotResult:
	var doc := source.duplicate(true)

	if int(doc.get("format", 0)) != FORMAT:
		return _refuse("format is %s; this build reads %d" % [str(doc.get("format")), FORMAT], doc)

	# Back to an int: JSON has one number type, and a document that came over the wire would
	# otherwise say 1.0 where the server's said 1, and the two digests would disagree.
	doc["format"] = FORMAT

	var kind := str(doc.get("kind", ""))

	if kind != KIND_COURSE and kind != KIND_ARENA:
		return _refuse("kind is \"%s\"; it is \"course\" or \"arena\"" % kind, doc)

	var id := str(doc.get("id", ""))

	if not _is_id(id):
		return _refuse("id \"%s\" is not lowercase a-z, 0-9 and _" % id, doc)

	doc["id"] = id
	doc["name"] = str(doc.get("name", id))
	doc["author"] = str(doc.get("author", ""))
	doc["blurb"] = str(doc.get("blurb", ""))
	doc["theme"] = _theme(doc.get("theme", {}))

	var pieces: Variant = doc.get("pieces", [])

	if typeof(pieces) != TYPE_ARRAY or (pieces as Array).is_empty():
		return _refuse("it has no pieces", doc)

	if (pieces as Array).size() > MAX_PIECES:
		return _refuse("it has %d pieces; the most is %d" % [(pieces as Array).size(), MAX_PIECES], doc)

	var normalised: Array = []

	for index in range((pieces as Array).size()):
		var checked := _piece((pieces as Array)[index], index)

		if not checked.ok:
			return checked.wrap("%s %s" % [kind, id])

		normalised.append(checked.value)

	doc["pieces"] = normalised

	var rest := _course(doc) if kind == KIND_COURSE else _arena(doc)

	if not rest.ok:
		return rest.wrap("%s %s" % [kind, id])

	return DotResult.success(doc)


static func _course(doc: Dictionary) -> DotResult:
	doc["water_height"] = float(doc.get("water_height", -8.0))
	doc["course_seconds"] = float(doc.get("course_seconds", 0.0))

	var start: Variant = doc.get("start")

	if typeof(start) != TYPE_DICTIONARY or not (start as Dictionary).has("at"):
		return DotResult.fail(DotError.CODE_INVALID, "A course needs a start: {at, size, yaw}.")

	doc["start"] = {
		"at": _v3((start as Dictionary)["at"]),
		"size": _v2((start as Dictionary).get("size", [10.0, 8.0])),
		"yaw": float((start as Dictionary).get("yaw", 0.0)),
	}

	var finish: Variant = doc.get("finish")

	if typeof(finish) != TYPE_DICTIONARY or not (finish as Dictionary).has("at"):
		return DotResult.fail(DotError.CODE_INVALID, "A course needs a finish: {at, size}.")

	doc["finish"] = {
		"at": _v3((finish as Dictionary)["at"]),
		"size": _v3((finish as Dictionary).get("size", [8.0, 4.0, 2.0])),
		"yaw": float((finish as Dictionary).get("yaw", 0.0)),
		# Where a finisher waits. The lounge is the finish's own platform unless a mapper
		# names one, and it is where somebody who has finished and then fallen off is put back.
		"lounge": _v3((finish as Dictionary).get("lounge", (finish as Dictionary)["at"])),
	}

	var checkpoints: Array = []

	for entry: Variant in doc.get("checkpoints", []):
		if typeof(entry) != TYPE_DICTIONARY or not (entry as Dictionary).has("at"):
			return DotResult.fail(DotError.CODE_INVALID, "A checkpoint needs at least an `at`.")

		checkpoints.append({
			"at": _v3((entry as Dictionary)["at"]),
			"size": _v3((entry as Dictionary).get("size", [10.0, 6.0, 3.0])),
			"yaw": float((entry as Dictionary).get("yaw", 0.0)),
		})

	doc["checkpoints"] = checkpoints

	# The round's weather, which a server adds to the document it sends. Every number a float,
	# because JSON has one number type: a tick written as 200 comes back 200.0, and the two
	# documents' bytes would disagree (headless_net's "the same document, to the byte").
	if typeof(doc.get("weather")) == TYPE_DICTIONARY:
		var weather := {"gusts": [], "strikes": []}
		for key in ["gusts", "strikes"]:
			for entry: Variant in (doc["weather"] as Dictionary).get(key, []):
				if typeof(entry) == TYPE_DICTIONARY:
					var floats := {}
					for field in (entry as Dictionary):
						floats[str(field)] = float((entry as Dictionary)[field])
					weather[key].append(floats)
		doc["weather"] = weather

	var route: Array = []

	for entry: Variant in doc.get("route", []):
		if typeof(entry) != TYPE_DICTIONARY or not (entry as Dictionary).has("at"):
			return DotResult.fail(DotError.CODE_INVALID, "A route point needs an `at`.")

		route.append({
			"at": _v3((entry as Dictionary)["at"]),
			"jump": bool((entry as Dictionary).get("jump", false)),
			"walk": bool((entry as Dictionary).get("walk", false)),
			"reach": float((entry as Dictionary).get("reach", 1.2)),
			# Hold here until the way to the next point is clear of every hazard for as long as
			# it takes to run it. See [method WoCourse.path_clear].
			"wait": bool((entry as Dictionary).get("wait", false)),
			# And until something will be under the next point when a jump lands there — a
			# mover, a turntable, a tile. See [method WoCourse.supported].
			"board": bool((entry as Dictionary).get("board", false)),
			# A point ON something that moves: standing on any carrier reaches it.
			"ride": bool((entry as Dictionary).get("ride", false)),
		})

	doc["route"] = route
	return DotResult.success(doc)


static func _arena(doc: Dictionary) -> DotResult:
	doc["kill_height"] = float(doc.get("kill_height", -10.0))

	var spawns: Array = []

	for entry: Variant in doc.get("spawns", []):
		if typeof(entry) != TYPE_DICTIONARY or not (entry as Dictionary).has("at"):
			return DotResult.fail(DotError.CODE_INVALID, "A spawn area needs an `at`.")

		spawns.append({
			"at": _v3((entry as Dictionary)["at"]),
			"size": _v2((entry as Dictionary).get("size", [4.0, 4.0])),
		})

	# [b]Two at the least, because the final death is between at least two sides.[/b] Four
	# is what a mapper should give it: with exactly as many areas as sides, the draw of who
	# goes where is the only thing left to chance and the arena plays the same every time.
	if spawns.size() < 2:
		return DotResult.fail(
			DotError.CODE_INVALID, "An arena needs at least two spawn areas (four is better)."
		)

	doc["spawns"] = spawns

	var drops: Array = []

	for entry: Variant in doc.get("drops", []):
		if typeof(entry) != TYPE_DICTIONARY or not (entry as Dictionary).has("at"):
			return DotResult.fail(DotError.CODE_INVALID, "A drop area needs an `at`.")

		drops.append({
			"at": _v3((entry as Dictionary)["at"]),
			"size": _v2((entry as Dictionary).get("size", [6.0, 6.0])),
		})

	if drops.is_empty():
		return DotResult.fail(DotError.CODE_INVALID, "An arena needs at least one drop area.")

	doc["drops"] = drops

	var gallery: Variant = doc.get("gallery")

	if typeof(gallery) != TYPE_DICTIONARY or not (gallery as Dictionary).has("at"):
		return DotResult.fail(
			DotError.CODE_INVALID, "An arena needs a gallery: {at, size} for everybody watching."
		)

	doc["gallery"] = {
		"at": _v3((gallery as Dictionary)["at"]),
		"size": _v2((gallery as Dictionary).get("size", [12.0, 6.0])),
	}

	return DotResult.success(doc)


static func _piece(source: Variant, index: int) -> DotResult:
	if typeof(source) != TYPE_DICTIONARY:
		return DotResult.fail(DotError.CODE_INVALID, "Piece %d is not an object." % index)

	var piece := (source as Dictionary).duplicate(true)
	var kind := str(piece.get("kind", ""))

	if not PIECES.has(kind):
		return DotResult.fail(
			DotError.CODE_INVALID,
			"Piece %d is a \"%s\", which this build does not know." % [index, kind],
			"known: %s" % ", ".join(PIECES.keys())
		)

	for field: String in PIECES[kind]:
		if not piece.has(field):
			return DotResult.fail(
				DotError.CODE_INVALID, "Piece %d (%s) has no `%s`." % [index, kind, field]
			)

	var role := str(piece.get("role", _default_role(kind)))

	if not ROLES.has(role):
		return DotResult.fail(
			DotError.CODE_INVALID, "Piece %d has role \"%s\"." % [index, role],
			"roles: %s" % ", ".join(ROLES)
		)

	var out := {"kind": kind, "role": role, "yaw": float(piece.get("yaw", 0.0))}

	# Every field this build reads, normalised, and nothing else. A field it does not read
	# would travel to every client and be ignored by both ends.
	for key: String in piece:
		match key:
			"kind", "role", "yaw":
				pass
			"at", "from", "to", "pivot", "size":
				out[key] = _v3(piece[key])
			"cols", "rows", "arms", "seed":
				out[key] = int(piece[key])
			"tint":
				out[key] = _colour(piece[key], Color.WHITE)
			"phase", "radius", "height", "length", "arm_length", "arm_height", "arm_thickness", \
					"hub_radius", "hub_height", "speed", "pitch", "amplitude", "period", \
					"swing", "reach", "duty", "tile", "gap", "thickness", "down", "power":
				out[key] = float(piece[key])
			_:
				pass

	# The few numbers that would divide by zero or never move, refused here rather than
	# found as a NaN in the middle of a round.
	if out.has("period") and float(out["period"]) <= 0.05:
		return DotResult.fail(DotError.CODE_INVALID, "Piece %d has a period of %s." % [index, out["period"]])

	if kind == "tiles" and (int(out["cols"]) < 1 or int(out["rows"]) < 1):
		return DotResult.fail(DotError.CODE_INVALID, "Piece %d has no tiles." % index)

	if out.has("size"):
		var size: Vector3 = out["size"]

		if size.x <= 0.0 or size.y <= 0.0 or size.z <= 0.0:
			return DotResult.fail(DotError.CODE_INVALID, "Piece %d has a size of %s." % [index, size])

	return DotResult.success(out)


static func _default_role(kind: String) -> String:
	match kind:
		"spinner", "pendulum", "pusher":
			return "hazard"
		"bouncer":
			return "safe"
		"mover", "turntable", "roller", "seesaw", "tiles", "conveyor":
			return "cannon"
		_:
			return "deck"


static func _theme(source: Variant) -> Dictionary:
	var theme: Dictionary = source if typeof(source) == TYPE_DICTIONARY else {}

	return {
		"sky": _colour(theme.get("sky"), Color(0.52, 0.72, 0.92)),
		"horizon": _colour(theme.get("horizon"), Color(0.82, 0.88, 0.94)),
		"water": _colour(theme.get("water"), Color(0.16, 0.42, 0.62)),
		"sun": _colour(theme.get("sun"), Color(1.0, 0.96, 0.88)),
	}


# --- The wire ---------------------------------------------------------------

## A normalised document as bytes: JSON, deflated, behind both its lengths.
##
## [b]The NORMALISED document, never the file.[/b] The server encodes what [method validate]
## returned and a client validates what it decodes, so both ends build from the same
## dictionary — and a client whose build is a format behind refuses it with a sentence rather
## than building a course with holes in it.
static func encode(doc: Dictionary) -> PackedByteArray:
	var text := JSON.stringify(_to_plain(doc), "", true)
	var raw := text.to_utf8_buffer()
	var packed := raw.compress(FileAccess.COMPRESSION_DEFLATE)

	var out := PackedByteArray()
	out.resize(8)
	out.encode_u32(0, raw.size())
	out.encode_u32(4, packed.size())
	out.append_array(packed)
	return out


static func decode(bytes: PackedByteArray) -> DotResult:
	if bytes.size() < 9:
		return DotResult.fail(DotError.CODE_PARSE, "A course on the wire was empty.")

	var size := bytes.decode_u32(0)

	# Both lengths, so a torn or padded body is refused here rather than handed to the
	# decompressor, which prints an engine error for it before returning nothing.
	if bytes.decode_u32(4) != bytes.size() - 8:
		return DotResult.fail(DotError.CODE_PARSE, "A course on the wire is not the length it says.")

	# A size this large is a corrupt header or somebody else's bytes; decompressing it would
	# allocate whatever it says.
	if size <= 0 or size > WIRE_LIMIT * 16:
		return DotResult.fail(DotError.CODE_PARSE, "A course on the wire says it is %d bytes." % size)

	var raw := bytes.slice(8).decompress(size, FileAccess.COMPRESSION_DEFLATE)

	if raw.size() != size:
		return DotResult.fail(DotError.CODE_PARSE, "A course on the wire would not decompress.")

	return parse_json(raw.get_string_from_utf8(), "wire")


## A short fingerprint of a document, for a log line and for two ends to compare.
static func digest(doc: Dictionary) -> String:
	return JSON.stringify(_to_plain(doc), "", true).sha256_text().substr(0, 12)


## Vectors and colours back to arrays, so JSON can carry them.
static func _to_plain(value: Variant) -> Variant:
	match typeof(value):
		TYPE_DICTIONARY:
			var out := {}
			for key: Variant in value:
				out[key] = _to_plain(value[key])
			return out
		TYPE_ARRAY:
			var out := []
			for item: Variant in value:
				out.append(_to_plain(item))
			return out
		TYPE_VECTOR3:
			var v: Vector3 = value
			return [v.x, v.y, v.z]
		TYPE_VECTOR2:
			var v: Vector2 = value
			return [v.x, v.y]
		TYPE_COLOR:
			var c: Color = value
			return [c.r, c.g, c.b]
		_:
			return value


# --- Small readers ----------------------------------------------------------

static func _v3(value: Variant) -> Vector3:
	if value is Vector3:
		return value

	if typeof(value) == TYPE_ARRAY and (value as Array).size() >= 3:
		return Vector3(float(value[0]), float(value[1]), float(value[2]))

	if typeof(value) == TYPE_ARRAY and (value as Array).size() == 2:
		return Vector3(float(value[0]), 1.0, float(value[1]))

	return Vector3.ZERO


static func _v2(value: Variant) -> Vector2:
	if value is Vector2:
		return value

	if typeof(value) == TYPE_ARRAY and (value as Array).size() >= 2:
		return Vector2(float(value[0]), float(value[1]))

	return Vector2(4.0, 4.0)


static func _colour(value: Variant, fallback: Color) -> Color:
	if value is Color:
		return value

	if typeof(value) == TYPE_ARRAY and (value as Array).size() >= 3:
		return Color(float(value[0]), float(value[1]), float(value[2]))

	if typeof(value) == TYPE_STRING and Color.html_is_valid(str(value)):
		return Color.html(str(value))

	return fallback


static func _is_id(id: String) -> bool:
	if id.is_empty() or id.length() > 48:
		return false

	for character in id:
		if not (character >= "a" and character <= "z") and not (character >= "0" and character <= "9") \
				and character != "_":
			return false

	return true


static func _refuse(why: String, doc: Dictionary) -> DotResult:
	return DotResult.fail(
		DotError.CODE_INVALID, "The document is refused: %s." % why, str(doc.get("id", "?"))
	)
