This is a game to demonstrate the capabilities of the [**Dot collection**](https://moddingcommunity.com/co/4-dot-assets) built on-top of [Godot 4](https://godotengine.org/) and [TMC's gaming platform](https://moddingcommunity.com/play). In this 3D game, players race across obstacle courses built over open water — sweeping arms, big balls, rolling logs, swinging hammers, rams that punch across narrow walkways, floors that drop away and rides across the gaps. Fall in and you go back to your last checkpoint. If two or more players (or teams) make it across the finish, they are thrown into a random arena for a **final death**: props and weapons rain in, and the last one standing wins.

The courses live in their own repository, [**mg-wipeout-maps**](https://github.com/gamemann/mg-wipeout-maps): ten courses and five arenas to start with, written as documents rather than scenes.

**This project and the assets under it are COMPLETELY OPEN SOURCE**. You are free to use, modify, and distribute them under the terms of the MIT license. The only thing not open source is the back-end web infrastructure.

## From Maintainer & WARNING
This project, along with every asset it is built on, was built initially with **Claude Code** and will continue to be maintained and extended using it. This is because I (`gamemann`) cannot build the entire TMC platform alone (I wish I could lol).

**Please treat this as early and partially tested.** It has four headless test suites and they pass — including one in which a stand-in runs every course to the finish — and it has been published as a signed pack and joined by a real client over a real socket, but none of it has been in front of real players yet. Expect rough edges, and please report anything you run into.

## A course, and sometimes a fight

Everybody starts on the same pad, behind the same gate. When it drops, the course is open: run, jump, time the arms, ride the movers. Nothing on a course can hurt you — falling in costs you the time it takes to run back from your last checkpoint, and an arm that catches you throws you, usually into the water. The course closes when everybody is across or the clock runs out, and then:

- **nobody finished** — whoever got furthest wins (or it is a draw, if `wo_progress_decides 0`);
- **one player or team finished** — they win outright;
- **two or more finished** — the final death. The finishers are dropped into an arena drawn at random, each side into a spawn area drawn at random, while props and weapons land across its floor. Pick things up with **E** and throw them with the left mouse button; walk over a weapon to take it. Fall out of the arena and you are out. Everybody who did not finish watches from the gallery.

Solo is the default: every player is their own side. `wo_teams 2` (up to 6) plays in teams, and then a team is through if anybody on it is.

## Running it

```bash
godot --path .                                                    # play it, alone, against stand-ins
godot --headless --path . res://examples/headless_run.tscn         # the simulation, 80 checks
godot --headless --path . res://examples/headless_courses.tscn     # a stand-in runs every course
godot --headless --path . res://examples/headless_net.tscn         # over the wire, 45 checks
godot --headless --path . res://examples/dedicated.tscn            # as a real server, 23 checks
tools/shot.sh --view=course --wo-course-ids=wo_spin_cycle           # render a course from above
tools/shot.sh --view=finale                                        # render a real final death
```

The courses are read from `courses/`, which `dot-bootstrap` links to the mg-wipeout-maps checkout. Without it the game still runs, on one practice course built into it.

## Controls

| | |
| --- | --- |
| WASD, mouse | Run and look |
| Space | Jump |
| Shift | Walk — for beams and ball tops |
| Ctrl | Crouch, under a high arm |
| E (hold) | Pick up, or put down, a prop |
| Left mouse | Throw what you are holding, or fire |
| Right mouse, R, 1–5 | Alt-fire, reload, weapon slots |
| F5 | First person / third person |

## Configuring a server

Every number is a cvar or an environment variable, layered `defaults < JSON < environment < command line` like everything else in this family. The ones an operator wants between rounds are live and write through to the running world.

```
wo_course_seconds 240       // the most a course stays open (a course may ask for less)
wo_finale_seconds 120       // how long a final death lasts before it is called
wo_teams 2                  // two teams; 0 is everybody for themselves
wo_props_per_side 8         // more to throw in a final death
wo_weapons_per_side 3       // more weapons on its floor
wo_knock_min 10             // obstacles throw harder
wo_progress_decides 0       // a round nobody finishes is a draw
wo_bot_fumble 25            // clumsier stand-ins
wo_min_players 6            // keep six racing with stand-ins
```

`wo_course_ids` and `wo_arena_ids` (on the command line or in the JSON file) limit a server to some courses and arenas. `wo_courses` lists what the server has and any document it refused, with the reason; `wo_reload` reads the course directory again for the next round; `wo_status` and `wo_net` say what the server is doing.

A moderator has dot-moderation's live tools: `noclip`, `freeze`, `speed`, `gravity`, `god`, `buddha`, `hp`, `slay`, `slap`, `rename`, the teleports, `blind` and `beacon`, and `respawn`, which puts a runner back at their last checkpoint. `give` and `strip` are refused: the weapons in a final death are the ones on its floor.

## Writing a course

A course is a JSON document — a start pad, a list of pieces, checkpoints and a finish — and a server reads every one in its course directory. The mg-wipeout-maps README is the format, with every kind of piece: still ground, ramps and balls; movers, turntables, rollers, seesaws, belts, drop-tiles and bouncers that carry you; and spinners, pendulums and pushers that throw you. A server sends the course to each client as the round begins, so players need no course files at all.

## What replicates, and what does not

| | |
| --- | --- |
| A player's own movement | **Predicted**, and corrected |
| Everybody else | Replicated and interpolated |
| **The course** | **Sent once, as a document, and never again.** Every obstacle is a function of the tick, so the client works out where every arm and mover is on its own — and a client predicting its own jump over an arm gets the same answer the server does |
| Checkpoints, finishes, falls | The server's decisions, as per-player state and events |
| Props in a final death | Server-authoritative mirrors, never predicted |
| Weapons on the floor | Events: a weapon appeared, a weapon was taken |

## The art

Every surface is [Kenney's](https://kenney.nl) **Prototype Textures**, one per role: still ground, supports, moving ground, the arena floor, anything that throws you, and the pads. The props are from Kenney's Survival and Car kits, the players are Kenney's Blocky Characters, and the weapons are [zee-dot-weapons](https://github.com/gamemann/zee-dot-weapons)' own. All of it is **CC0**.

The courses are built in code from their documents, so a new course is a JSON file and not a scene. A delivered server gets them as a second pack: this game's `game.yml` names `gamemann/mg-wipeout-maps` under `server_dependencies`, the server mounts it beside the game, and the game reads every course and arena in it. Clients never get the course files; they are sent the one being played as the round begins.

A drop-tile goes red for a moment before it falls, and a high arm is one to duck rather than jump.

## What does not work yet

- **Stand-ins race by the document's route.** They wait for windows they can compute and hop arms they see coming, which is enough to finish every course, but they are not clever about a crowded beam, and in a final death they are four lines of brain.
- **The obstacles make no sound of their own.** A knock, a splash, a checkpoint and the gate do; an arm turning and a ram firing do not yet.
- **No settings screen**, for the reason mg-smash-copter gives: there is no menu to put one in.

## Licence

MIT. See [LICENSE](LICENSE).

The art is the exception, and it is a more permissive one: the prototype textures, the props, the characters and the weapon models are CC0 1.0, public domain with no attribution required. Each kit's own licence text ships unchanged beside the files it covers.
