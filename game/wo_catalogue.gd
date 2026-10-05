extends RefCounted

const WoCourseDoc := preload("wo_course_doc.gd")
const WoPaths := preload("wo_paths.gd")

## Every course and arena this server can play, and which one is next.
##
## [b]Two sources, and the built-in one is a floor rather than a feature.[/b] The courses are
## the mg-wipeout-maps repository's, read from [member WoConfig.course_directory] — a link in
## a checkout, a directory in a delivered pack. A server whose directory is missing or empty
## still has [method practice] and [method practice_arena], so it plays rather than refusing
## to start; that is the state a fresh clone without the maps repository is in, and nothing
## in it is broken.
##
## [b]A server reads documents; a client never does.[/b] The course travels in the round's
## first event (see [WoCourseDoc]), so nothing here runs on a connected client.

const CHANNEL := "wo.catalogue"

## id -> normalised document.
var courses: Dictionary = {}
var arenas: Dictionary = {}

## Files that were refused, with why. What `wo_courses` prints, so a mapper can see it.
var refused: Dictionary = {}

## The order courses come up in when they are not shuffled.
var _order: Array[StringName] = []
var _next: int = 0


## Reads every document under [param directory] (relative to this game's root), and adds the
## two built in.
func load_from(directory: String) -> int:
	courses.clear()
	arenas.clear()
	refused.clear()

	_add(practice(), "built-in")
	_add(practice_arena(), "built-in")

	var root := WoPaths.rebase("res://" + directory.trim_prefix("res://").trim_prefix("/"))
	var dir := DirAccess.open(root)

	if dir == null:
		DotLog.info(CHANNEL, "no course directory; playing the built-in course only", {
			"looked_at": root,
		})
		_rebuild_order()
		return 0

	var files := PackedStringArray()

	for file in dir.get_files():
		# A delivered pack may hold `.json.remap`-free copies only; anything that is not
		# a document is somebody's README.
		if file.ends_with(".json"):
			files.append(file)

	# Sorted, so the order a server plays them in does not depend on the filesystem.
	files.sort()

	var loaded := 0

	for file in files:
		var path := root.path_join(file)
		var text := FileAccess.get_file_as_string(path)

		if text.is_empty():
			refused[file] = "empty or unreadable"
			continue

		var parsed := WoCourseDoc.parse_json(text, file)

		if not parsed.ok:
			refused[file] = parsed.error.message
			# WARN: a server is running without a course somebody installed, and the mapper
			# needs the sentence. Not ERROR: every other course still plays.
			DotLog.warn(CHANNEL, "a document was refused", {
				"file": file, "why": parsed.error.message, "detail": parsed.error.detail,
			})
			continue

		if _add(parsed.value, file):
			loaded += 1

	_rebuild_order()

	DotLog.info(CHANNEL, "courses loaded", {
		"courses": courses.size(), "arenas": arenas.size(), "refused": refused.size(),
	})
	return loaded


func _add(doc: Dictionary, origin: String) -> bool:
	var id := StringName(str(doc["id"]))
	var into := courses if str(doc["kind"]) == WoCourseDoc.KIND_COURSE else arenas

	if into.has(id) and origin != "built-in":
		# A file named after a built-in replaces it, which is how a server improves on the
		# practice course without a code change. Two FILES with one id is a mistake.
		if not _is_builtin(id):
			refused[origin] = "a second document with id %s" % id
			return false

	into[id] = doc
	return true


static func _is_builtin(id: StringName) -> bool:
	return id == &"wo_practice" or id == &"wo_practice_arena"


func _rebuild_order() -> void:
	_order.clear()

	for id: StringName in courses:
		_order.append(id)

	_order.sort_custom(func(a: StringName, b: StringName) -> bool: return String(a) < String(b))
	_next = 0


## The ids a server may draw from, after [param allowed] (empty is all). The built-in
## practice course drops out once there is anything else, because a server with ten real
## courses should not spend one round in eleven on the tutorial.
func playable_courses(allowed: PackedStringArray) -> Array[StringName]:
	var out: Array[StringName] = []

	for id in _order:
		if allowed.is_empty() or allowed.has(String(id)):
			out.append(id)

	if allowed.is_empty() and out.size() > 1:
		out.erase(&"wo_practice")

	return out


func playable_arenas(allowed: PackedStringArray) -> Array[StringName]:
	var out: Array[StringName] = []

	for id: StringName in arenas:
		if allowed.is_empty() or allowed.has(String(id)):
			out.append(id)

	out.sort_custom(func(a: StringName, b: StringName) -> bool: return String(a) < String(b))

	if allowed.is_empty() and out.size() > 1:
		out.erase(&"wo_practice_arena")

	return out


## The next course: drawn from [param stream] when shuffling, in order otherwise.
##
## [b]Never the same course twice running when there is a choice[/b], because a shuffle that
## repeats is the thing every player notices first and reports as the rotation being broken.
func next_course(allowed: PackedStringArray, shuffle: bool, stream: DotRandomStream,
		previous: StringName) -> Dictionary:
	var ids := playable_courses(allowed)

	if ids.is_empty():
		DotLog.warn(CHANNEL, "no course matches the allowed list; playing practice", {
			"allowed": ",".join(allowed),
		})
		return courses.get(&"wo_practice", practice())

	var pick: StringName

	if shuffle and stream != null:
		pick = ids[stream.next_range_i(0, ids.size() - 1)]

		if pick == previous and ids.size() > 1:
			pick = ids[(ids.find(pick) + 1 + stream.next_range_i(0, ids.size() - 2)) % ids.size()]
	else:
		pick = ids[_next % ids.size()]
		_next += 1

	return courses[pick]


func pick_arena(allowed: PackedStringArray, stream: DotRandomStream) -> Dictionary:
	var ids := playable_arenas(allowed)

	if ids.is_empty():
		return arenas.get(&"wo_practice_arena", practice_arena())

	return arenas[ids[stream.next_range_i(0, ids.size() - 1)] if stream != null else ids[0]]


func describe_lines() -> PackedStringArray:
	var lines := PackedStringArray(["courses (%d)" % courses.size()])

	for id in _order:
		var doc: Dictionary = courses[id]
		lines.append("  %-22s %-24s %d pieces  %s" % [
			id, str(doc["name"]), (doc["pieces"] as Array).size(), str(doc["author"]),
		])

	lines.append("arenas (%d)" % arenas.size())

	for id: StringName in arenas:
		var doc: Dictionary = arenas[id]
		lines.append("  %-22s %-24s %d spawn areas" % [
			id, str(doc["name"]), (doc["spawns"] as Array).size(),
		])

	if not refused.is_empty():
		lines.append("refused (%d)" % refused.size())

		for file: String in refused:
			lines.append("  %-22s %s" % [file, refused[file]])

	return lines


# --- The two built in ---------------------------------------------------------

## A short course of one of each family of obstacle: still ground, a carrier, a hazard.
##
## [b]Written here rather than shipped as a file,[/b] so a server with no course directory
## at all — a fresh clone, a suite — has something to play and the suites have a course whose
## every number is in front of them.
static func practice() -> Dictionary:
	var doc := {
		"format": 1,
		"kind": "course",
		"id": "wo_practice",
		"name": "Practice Run",
		"author": "mg-wipeout",
		"blurb": "Three things to cross before the real courses: a gap, an arm and a ride.",
		"water_height": -6.0,
		"start": {"at": [0.0, 0.0, 0.0], "size": [10.0, 8.0], "yaw": 0.0},
		"pieces": [
			# Run-out from the start pad.
			{"kind": "box", "at": [0.0, -0.5, -9.0], "size": [6.0, 1.0, 10.0]},
			# A 2.5 m gap, inside a running jump, onto a landing.
			{"kind": "box", "at": [0.0, -0.5, -21.5], "size": [6.0, 1.0, 10.0]},
			# A sweeping arm at shin height across the landing: jump it.
			{"kind": "spinner", "at": [0.0, 0.0, -21.5], "arm_length": 4.6, "arm_height": 0.55,
				"speed": 75.0, "arms": 2},
			# A mover across a 9 m gap.
			{"kind": "box", "at": [0.0, -0.5, -29.5], "size": [6.0, 1.0, 6.0], "role": "safe"},
			{"kind": "mover", "from": [0.0, -0.4, -35.5], "to": [0.0, -0.4, -41.5],
				"size": [4.0, 0.6, 4.0], "period": 5.0},
			{"kind": "box", "at": [0.0, -0.5, -48.0], "size": [8.0, 1.0, 8.0], "role": "safe"},
		],
		"checkpoints": [
			{"at": [0.0, 0.0, -29.0], "size": [6.0, 4.0, 2.0]},
		],
		"finish": {"at": [0.0, 0.0, -47.0], "size": [8.0, 4.0, 2.0], "lounge": [0.0, 0.0, -49.0]},
		"route": [
			{"at": [0.0, 0.0, -3.2], "reach": 1.0},
			{"at": [0.0, 0.0, -13.5], "jump": true, "reach": 0.55},
			{"at": [0.0, 0.0, -18.0]},
			# Round the arm's post, not through it; the arm itself is hopped.
			{"at": [1.8, 0.0, -20.0]},
			{"at": [1.8, 0.0, -23.5]},
			{"at": [0.0, 0.0, -25.5]},
			# Two metres back from the edge to wait for the mover, then on it, then off it.
			{"at": [0.0, 0.0, -30.5], "reach": 0.6},
			{"at": [0.0, 0.0, -35.5], "board": true, "ride": true, "reach": 0.9},
			{"at": [0.0, 0.0, -45.5], "board": true, "reach": 0.9},
			{"at": [0.0, 0.0, -47.5]},
		],
	}

	var checked := WoCourseDoc.validate(doc)
	return checked.value if checked.ok else doc


## A square with four corners to start in and a gallery along one side.
static func practice_arena() -> Dictionary:
	var doc := {
		"format": 1,
		"kind": "arena",
		"id": "wo_practice_arena",
		"name": "The Square",
		"author": "mg-wipeout",
		"blurb": "Four corners, one middle, everything you need in the middle.",
		"kill_height": -8.0,
		"pieces": [
			{"kind": "box", "at": [0.0, -0.5, 0.0], "size": [26.0, 1.0, 26.0], "role": "arena"},
			{"kind": "box", "at": [0.0, 0.6, 0.0], "size": [3.0, 1.2, 3.0], "role": "pillar"},
		],
		"spawns": [
			{"at": [-9.0, 0.0, -9.0], "size": [4.0, 4.0]},
			{"at": [9.0, 0.0, 9.0], "size": [4.0, 4.0]},
			{"at": [9.0, 0.0, -9.0], "size": [4.0, 4.0]},
			{"at": [-9.0, 0.0, 9.0], "size": [4.0, 4.0]},
		],
		"drops": [{"at": [0.0, 0.0, 0.0], "size": [12.0, 12.0]}],
		"gallery": {"at": [0.0, 6.0, 20.0], "size": [14.0, 5.0]},
	}

	var checked := WoCourseDoc.validate(doc)
	return checked.value if checked.ok else doc
