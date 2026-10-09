This is a game to demonstrate the capabilities of the [**Dot collection**](https://moddingcommunity.com/co/4-dot-assets) built on-top of [Godot 4](https://godotengine.org/) and [TMC's gaming platform](https://moddingcommunity.com/play). In this 3D game, players race across obstacle courses built over water: sweeping arms, big balls, rolling logs, swinging hammers and floors that drop away. Fall in and you go back to your last checkpoint. If more than one player (or team) makes it to the finish, they fight it out in a random arena with props and weapons until one is left standing. This is inspired by the obstacle-course game shows on TV!

**This project and the assets under it are COMPLETELY OPEN SOURCE**. You are free to use, modify, and distribute them under the terms of the MIT license. The only thing not open source is the back-end web infrastructure. So if you opt into using your own authentication backend instead of integrating with TMC, you will need to build and integrate your own back-end infrastructure.

## From Maintainer & WARNING
This project, along with every asset it is built on, was built initially with **Claude Code** and will continue to be maintained and extended using it. This is because I (`gamemann`) cannot build the entire TMC platform alone (I wish I could lol).

**Please treat this as partially tested.** It has its own headless test suite and that suite passes, but very little of this has been in front of real players yet. Expect rough edges, and please report anything you run into.

I intend on reviewing code, testing, and editing documentation regularly. If you're interested in helping out, please let me know!

## How it plays
Everybody starts on the same pad behind a gate. When the gate drops, run, jump, time the arms and ride the moving platforms. Nothing on the course can hurt you: falling in just sends you back to your last checkpoint, and an arm that catches you throws you, usually into the water. Red tiles are about to drop, and a high arm is one to duck under rather than jump.

The course closes when everybody is across or the clock runs out. Then:

- **Nobody finished:** whoever got furthest wins (or it's a draw, with `wo_progress_decides 0`).
- **One player or team finished:** they win.
- **Two or more finished:** the **final death**. The finishers are dropped into a random arena while props and weapons land on its floor. Pick props up with **E** and throw them, or walk over a weapon to take it. Fall out of the arena and you're out. Everybody else watches from the gallery.

Every player is their own side by default. `wo_teams 2` (up to 6) plays in teams, and a team is through if anybody on it finishes.

The courses live in their own repository, [mg-wipeout-maps](https://github.com/gamemann/mg-wipeout-maps): ten courses and five arenas, each a JSON file. Without it the game still runs, on one practice course built in.

## Controls

| Key | Action |
| --- | --- |
| **WASD** / mouse | Run and look |
| **Space** | Jump |
| **Shift** | Walk (for beams and the tops of balls) |
| **Ctrl** | Crouch, under a high arm |
| **E** (hold) | Pick up or put down a prop |
| **Mouse 1** | Throw what you are holding, or fire |
| **Mouse 2** / **R** / **1**-**5** | Alt-fire / reload / weapon slots |
| **F5** | First or third person |
| **Tab** | Scoreboard |

## Getting started
You need [Godot 4.7](https://godotengine.org/download). The game is built from many Dot addons, each in its own repository, so the easiest way to get everything is [dot-bootstrap](https://github.com/modcommunity/dot-bootstrap). It clones every project and links the addons into each one:

```bash
git clone https://github.com/modcommunity/dot-bootstrap.git
cd dot-bootstrap
./bootstrap.sh
cd projects/mg-wipeout
./game.sh
```

On Windows, run `bootstrap.ps1` instead and open the project in Godot.

The courses come from the mg-wipeout-maps checkout, which bootstrap links into `courses/` for you. On a deployed server they come from the server instead: the game ships only its built-in practice course, and the server owner picks the courses pack (`gamemann/mg-wipeout-maps`, or their own) in dot-server-deploy's `cfg/content.yml`.

`game.sh` does everything else:

| Command | What it does |
| --- | --- |
| `./game.sh` | Play offline against bots |
| `./game.sh online` | Start a local server and the browser client, and print the link to open |
| `./game.sh online down` | Stop them |
| `./game.sh server` | Start a local dedicated server only |
| `./game.sh test` | Check every script and run every test suite |
| `./game.sh shot` | Save a screenshot to `screenshots/`. `./game.sh shot --help` lists the views |
| `./game.sh help` | All of the options |

`online` and `server` use [dot-server-deploy](https://github.com/modcommunity/dot-server-deploy), which bootstrap clones next to this one. Run its `./setup.sh` once first.

## Running a server
Settings are cvars. Set them in the server's config, on the command line, or live from the console. Most of them take effect straight away.

```
wo_course_seconds 210       // the longest a course stays open (a course may ask for less)
wo_finale_seconds 100       // how long a final death lasts
wo_teams 0                  // 0 = everybody for themselves, 2-6 = teams
wo_props_per_side 6         // props to throw in a final death
wo_weapons_per_side 2       // weapons on the arena floor
wo_knock_min 8              // how hard the obstacles throw you
wo_progress_decides 1       // 0 = a round nobody finishes is a draw
wo_bot_fumble 12            // how clumsy the bots are
wo_min_players 3            // fill the race with bots up to this
wo_bots 1                   // 0 = no bots
```

`--wo-course-ids=<ids>` and `--wo-arena-ids=<ids>` limit a server to some courses and arenas.

Console commands:

| Command | |
| --- | --- |
| `wo_status` | What the server is doing |
| `wo_courses` | The courses the server has, and any it refused (with the reason) |
| `wo_reload` | Read the course folder again, for the next round |
| `wo_net` | What the network code is doing |

### Admin commands
These come from [dot-moderation](https://github.com/modcommunity/dot-moderation): `noclip`, `freeze`, `speed`, `gravity`, `god`, `buddha`, `hp`, `slay`, `slap`, `rename`, the teleports, `blind` and `beacon`. `respawn` puts a runner back at their last checkpoint. `give` and `strip` are turned off, because the weapons in a final death are the ones on its floor.

## Writing a course
A course is a JSON file: a start pad, a list of pieces, checkpoints and a finish. The [mg-wipeout-maps](https://github.com/gamemann/mg-wipeout-maps) README describes the format and every kind of piece. The server sends the course to each player when the round starts, so players don't need the course files.

## Testing

```bash
./game.sh test                      # every script parses, then every suite runs
./game.sh test headless_courses     # one suite
```

| Suite | What it covers |
| --- | --- |
| `headless_run` | The game itself: rounds, checkpoints, falls, the final death |
| `headless_courses` | A bot runs every course to the finish |
| `headless_net` | A server and a client in one process, over the network code |
| `dedicated` | A real server: boots, loads the game, runs its commands |

[`CLAUDE.md`](CLAUDE.md) has the design decisions and the reasoning behind them.

## Not done yet
- Bots finish every course, but they aren't clever about a crowded beam, and they are weak in the final death.
- The obstacles themselves make no sound yet (knocks, splashes, checkpoints and the gate do).
- There is no settings menu.

## Credits
Every surface is Kenney's Prototype Textures; the props are from Kenney's Survival and Car kits and the players are Kenney's Blocky Characters ([kenney.nl](https://kenney.nl), CC0). The weapons are from [zee-dot-weapons](https://github.com/gamemann/zee-dot-weapons). Each kit's licence is next to its files.

## License
MIT. See [LICENSE](LICENSE). The Kenney art is CC0, which is public domain.
