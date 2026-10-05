extends RefCounted

## Where this game's own files are, wherever this copy of it happens to live.
##
## [b]A delivered pack does not mount at the path its content was authored at.[/b] It
## mounts at [code]res://dot_cloud/<id>/<version>/[/code], so every absolute `res://`
## reference a game makes to its OWN files resolves against the HOST project root
## instead — which holds another game's file, or nothing. The pack mounts, the scene
## loads, and the first thing that tries to use the reference finds something else.
##
## A script knows where it is: `resource_path` is the mounted path, not the authored one.
## So this game's root is this script's directory with the `game/` segment taken off, and
## every other path hangs off that.
##
## [codeblock]
## load(WoPaths.rebase("res://props/wo_crate.tscn"))
## [/codeblock]
##
## Built in, [method rebase] returns exactly what it was passed, so nothing about today's
## behaviour changes. That is the point: one form that is right in both.
##
## [b]Which means anything holding one of these paths is a `static var`, not a
## `const`.[/b] A constant is folded at parse time and [method root] is not knowable then.

const _SELF := preload("wo_paths.gd")


## This game's content root: `res://` built in, the mount prefix delivered.
static func root() -> String:
	# Through [Resource], because a const-preloaded script is typed as its own class and
	# `resource_path` is not reachable on that — "Cannot find member resource_path in
	# base res://…". The cast costs nothing and is the only spelling that compiles.
	var here: Resource = _SELF
	return here.resource_path.get_base_dir().get_base_dir()


## Moves one `res://` path onto [method root].
##
## Anything that is not a `res://` path comes back untouched, so this is safe to wrap
## around a value that may already be absolute or may be a `user://` path.
##
## Format specifiers survive: only the prefix is replaced, so
## `rebase("res://textures/%s.png") % name` works exactly as it read before.
static func rebase(path: String) -> String:
	return rebase_onto(path, root())


## [method rebase], against a root given rather than discovered.
##
## [b]This split exists so the mounted case can be TESTED from a build.[/b] Built in,
## [method root] is `res://` and every `res://` path is already under it — so every
## property of [method rebase] that matters only in a pack is a tautology here, and a suite
## asserting them passes whatever the body says. Breaking the idempotence below and
## re-running the suite proved it: 101 passed, 0 failed, with the bug that cost a boot put
## back. A check that cannot fail is the family's own worst kind, and this is the only
## spelling that gives the suite a real mount prefix to work against.
static func rebase_onto(path: String, here: String) -> String:
	if not path.begins_with("res://"):
		return path

	# [b]Idempotent, and finding out why cost a boot.[/b] The publisher REWRITES every
	# `res://` string inside a `.tscn`, a `.tres` and a `.import` onto the mount prefix
	# before it signs the pack — it has to, because a scene's `ext_resource` paths would
	# otherwise point at the host — and it does NOT rewrite the ones inside a `.gd`, because
	# a script is not a resource file it can parse. So a game ends up with both kinds: a
	# `const` in a script that still says `res://props/x.tscn` and needs rebasing, and an
	# exported property on a node that the publisher has already turned into
	# `res://dot_cloud/<id>/<version>/props/x.tscn` and must not be. Rebasing the second
	# produces `res://dot_cloud/tmc/smash/0.1.0/dot_cloud/tmc/smash/0.1.0/...`, which fails
	# to load with a path long enough that the doubling is easy to miss.
	#
	# This is the seventh form of the family's one delivery bug. The other six are in
	# ../../CLAUDE.md; what they share is that the thing being rewritten and the thing doing
	# the rewriting cannot see each other.
	#
	# Built in, [param here] is `res://` and every `res://` path is already under it, so this
	# returns its argument unchanged — which is what it did before.
	if path.begins_with(here):
		return path

	return here.path_join(path.substr(6))
