extends RefCounted

const WoConfig := preload("wo_config.gd")
const WoPaths := preload("wo_paths.gd")

## The props a final death drops: what a player picks up and throws.
##
## [b]Five, all of them light enough to carry and heavy enough to matter.[/b] mg-smash-
## copter's catalogue had four tiers up to a 900 kg monolith, because its props were thrown by
## a cannon; these are thrown by a person, through dot-props' gravity gun, and a prop is only
## worth having here if it can be picked up. The damage a throw does is its momentum
## ([member WoConfig.throw_damage_per_impulse]), so the boulder is the heavy hitter and the
## cone a nuisance, and the barrel is the one that goes off.

## Where the bodies live, rebased where they are defined (see mg-smash-copter, where a
## `const` rebased at each call site was one new call site away from a prop that does not
## spawn in a delivered round).
static var CRATE_SCENE := WoPaths.rebase("res://props/wo_crate.tscn")
static var TYRE_SCENE := WoPaths.rebase("res://props/wo_tyre.tscn")
static var CONE_SCENE := WoPaths.rebase("res://props/wo_cone.tscn")
static var BARREL_SCENE := WoPaths.rebase("res://props/wo_barrel.tscn")
static var BOULDER_SCENE := WoPaths.rebase("res://props/wo_boulder.tscn")

const CRATE := &"crate"
const TYRE := &"tyre"
const CONE := &"cone"
const BARREL := &"barrel"
const BOULDER := &"boulder"

## Who owns anything the world puts out itself. Not the empty string, which dot-props reads
## as a player and charges a per-player budget to.
const WORLD_OWNER := &"world"


static func props(_config: WoConfig) -> DotPropCatalogue:
	var catalogue := DotPropCatalogue.new()

	var crate := DotPropDef.make(CRATE, CRATE_SCENE)
	crate.display_name = "Crate"
	crate.category = &"debris"
	crate.size = DotPropDef.Size.SMALL
	crate.mass = 30.0
	crate.rideable = true
	crate.max_health = 60.0
	# A crate thrown into a wall at speed breaks, which is a crate used up: it is the one prop
	# a player has to decide whether to spend.
	crate.break_impact_speed = 18.0
	catalogue.add(crate)

	var tyre := DotPropDef.make(TYRE, TYRE_SCENE)
	tyre.display_name = "Tyre"
	tyre.category = &"debris"
	tyre.size = DotPropDef.Size.SMALL
	tyre.mass = 22.0
	tyre.rideable = true
	# Indestructible, and it rolls: a miss keeps going, which on a floor with an edge is a
	# second chance at somebody.
	tyre.max_health = 0.0
	catalogue.add(tyre)

	var cone := DotPropDef.make(CONE, CONE_SCENE)
	cone.display_name = "Cone"
	cone.category = &"debris"
	cone.size = DotPropDef.Size.SMALL
	cone.mass = 9.0
	cone.rideable = false
	cone.max_health = 25.0
	cone.break_impact_speed = 14.0
	catalogue.add(cone)

	var barrel := DotPropDef.make(BARREL, BARREL_SCENE)
	barrel.display_name = "Barrel"
	barrel.category = &"hazard"
	barrel.size = DotPropDef.Size.SMALL
	barrel.mass = 40.0
	barrel.rideable = true
	# Low health and a low break speed: a barrel thrown hard enough to hurt somebody is a
	# barrel that goes off, and standing next to one somebody else is carrying is the risk.
	barrel.max_health = 22.0
	barrel.break_impact_speed = 11.0
	barrel.explode_radius = 4.5
	barrel.explode_damage = 70.0
	barrel.explode_force = 900.0
	catalogue.add(barrel)

	var boulder := DotPropDef.make(BOULDER, BOULDER_SCENE)
	boulder.display_name = "Boulder"
	boulder.category = &"debris"
	boulder.size = DotPropDef.Size.MEDIUM
	boulder.mass = 60.0
	boulder.rideable = true
	boulder.max_health = 0.0
	catalogue.add(boulder)

	return catalogue
