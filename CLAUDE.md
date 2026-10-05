# mg-wipeout

Obstacle courses over water; if two or more sides finish, a final death in a random arena with props to throw and weapons on the floor.

Read the family-wide conventions in [`../../CLAUDE.md`](../../CLAUDE.md) first, and each addon's own `CLAUDE.md` before working in it. This file is only about what this game decides. The courses are the [mg-wipeout-maps](../mg-wipeout-maps) repository's; its `CLAUDE.md` is about authoring them.

**Built 2026-10-05, in one session, from mg-smash-copter's skeleton** (module, services, wire, client, HUD, spectate, progress, avatars, figure, beacon — renamed `sc` → `wo` and then rewritten wherever they named a platform, the cannon or the chopper). Where a comment says "mg-smash-copter found…", the finding is that game's and the line was kept because it is still true here; the note in that repository is the long version.

## What this game is, versus the other seven

game-arena is a deathmatch, g2gfast a timer server, playground a sandbox, hungario an eating game, the lobby a lobby, buses asymmetric, smash-copter a floor that tips. This is the first whose obstacles are **scripted machinery** — arms, hammers, rams, rides — and whose first phase cannot hurt anybody: a fall costs time (back to the last checkpoint), a knock costs dignity. The second phase is mg-smash-copter's idea (the good ones finish in a fight) with the fight made physical: props carried with dot-props' gravity gun and thrown, and weapons found rather than dealt.

## Layout

```
game/
  wo_config.gd       every rule a course is played under (the courses themselves are documents)
  wo_course_doc.gd   what a course and an arena ARE: JSON, validated, normalised, sent on the wire
  wo_course.gd       THE FILE. A document built into pieces; every piece a function of the tick
  wo_catalogue.gd    every document the server has, one built-in course and arena, which is next
  wo_controller.gd   DotFpsController with the pre/post-simulate hooks the course needs
  wo_player.gd       one person: movement, the carry/bounce/knock after each tick, progress, hands
  wo_rules.gd        a DotMatchRules whose outcome is whatever WoGame decided
  wo_game.gd         the simulation: phases, falls, checkpoints, the finish, the final death, bots
  wo_content.gd      the five props a final death drops
  wo_hud.gd          the clock, the phase, the course's name, a progress bar, health in a fight
  wo_audio.gd        splash, knock, checkpoint, finish, gate, and the fight's noises
  wo_client.gd       one local player, alone or against a server; poses the course per frame
  wo_module.gd       the DotGameModule: cvars, wo_status / wo_courses / wo_reload, stand-ins
  wo_services.gd     chat, voice and moderation over dot-game's base (respawn = last checkpoint)
  net/               the codec (STAGE, PROGRESS, PICKUP…), the link, two behaviours, the bridge
courses -> ../mg-wipeout-maps/courses   (a dot-bootstrap link; .gitignore says so)
examples/            headless_run (82), headless_courses (every course), headless_net (45), dedicated (23)
tools/               shot.sh/.gd — render a view; trace_course — where a stand-in falls and why
```

## Decision 1: an obstacle is a pure function of the tick

mg-smash-copter's platforms are a spring the server integrates and replicates, because what they do depends on who is standing on them. Nothing here does. An arm turns at a speed, a mover eases with a period, a tile drops on a schedule hashed from its index — so **where every obstacle is at tick N is a formula both ends evaluate, and nothing about the course is ever replicated after the document arrives**. A client predicting its own player poses the course at the tick it is simulating, first (`WoController._on_pre_simulate`, which dot-player-controller documents as running during prediction replays too), so a jump over a sweeping arm lands or fails identically on both ends. `headless_net`'s "every obstacle is where the server has it" asserts it from both ends at five ticks and 240 knock queries; armed by not giving the client's course the server's tick rate (three checks fail).

**Hazards are not solid to a player; carriers are.** A swept capsule meeting a body that moved into it between ticks is resolved by depenetration, which is order-dependent and differs between machines. So spinners, pendulums and pushers are measured analytically against the player's capsule (`WoCourse.knock`: segment–segment for an arm, point–segment for a ball, sampled box for a ram) and throw at the surface's own speed, clamped to `knock_min_speed`..`knock_max_speed`, plus `knock_lift`. Movers, turntables, rollers, seesaws, belts and tiles are solid, and whoever stands on one is moved by `WoCourse.carry` — the exact displacement `pose(t+dt)·pose(t)⁻¹·p − p`, not a velocity times a step, or a player standing still on a turntable spirals off it (`headless_run` holds the radius over three seconds).

**Moving pieces are STATIC bodies, teleported — never `AnimatableBody3D`.** Godot's physics server applies a new transform to a kinematic body only at its next step (the first lands at once, later ones wait). The course suite, which drives ticks without physics frames, found the turntables and rollers still at the origin where they were built; a client replaying six predicted ticks in one frame would have swept all six against obstacles a frame old. A static body's transform, written through `PhysicsServer3D.body_set_state` as well as the node (`WoCourse._place`), is applied immediately. A frame posed between ticks (`pose_at_time`, client drawing) forgets its cached tick so the next `pose_at(N)` re-poses.

## Decision 2: the course travels, whole

A course is a JSON document (`WoCourseDoc`); the server reads documents from `courses/` and sends the **normalised** one in `STAGE` (deflated, both lengths in a header, refused rather than decompressed when torn). A client needs no course files and cannot disagree about where a deck is, because there is one copy and it travelled — mg-smash-copter's Decision 4, taken further. The client validates what it receives, so a client a format behind refuses with a sentence rather than building a course with holes. `headless_net` checks the client's course digest equals the server's.

**The warmup's course is round one's.** `_ready` lays a course out (so a world is never empty), `start()` rebuilds the same one (on a server the bridge only exists by then, so this is the build clients are sent), and the first round keeps it (`_course_unplayed`); every later round draws the next (seeded, never the same twice running).

## Decision 3: a round is decided by the game, not by dot-match

`WoRules` returns CUSTOM when `WoGame` has decided and the winner it decided; its only clock is a backstop (`countdown + course + handover + finale + 60 s`) so a round the game somehow never decided still ends — and dot-match stops warning at boot that nothing but a custom outcome can end one. Solo is the default: each player is a side of their own, numbered from `SOLO_SIDE_BASE` (100), so `team_of` gives dot-combat distinct sides (friendly fire is off, and a solo game where everybody answered side 0 would be everybody's team-mate). Sides are therefore varints on the wire, not three bits.

Course closed → `finishing_sides()`: ≥2 → handover into a drawn arena (spawn areas shuffled per round, positions drawn inside them, props and weapons drawn across the drop areas, non-finishers into the gallery, everybody invulnerable for `handover_seconds`); 1 → that side; 0 → the furthest checkpoint (`progress_decides`), else a draw. Final death: last side with anybody up and not watching; the clock → most people up, else a draw.

## The final death

**Props are carried with dot-props' `DotGravGun`, one per player, server-side only.** The grab key rides in this game's own `WoNetCommand` (`grab`), because `DotFpsCommand`'s three spare buttons are fire, alt-fire and reload; the server turns the held state into an edge. Fire while carrying throws (`throw_impulse`). A thrown prop is "thrown" for three seconds and hurts by momentum (`throw_damage_per_impulse`) whoever it meets, once per prop per 20 ticks, credited to the thrower. **Weapons are found**: pickups laid on the floor (`PICKUP`/`PICKUP_GONE` events), taken by standing on them, which builds a `ZeeWeaponRig` the first time (`WoGame.arm`). The client draws each pickup as zee's own world model, spinning, with a light under it.

## Stand-ins

They run the document's route (`route` in mg-wipeout-maps). The flags are the whole brain, and each was earned by watching a bot fail in `tools/trace_course`:

- `jump` — jump here, **once on the ground** (a jump point passed in the air was skipped, and the bot slid off the ball it landed on); and get up to speed for up to three ticks first (a landing on a turning log costs speed, and a slow jump falls short — a jump is cut short in the air, never stretched).
- In the air toward a `jump` point, `_bot_land_on` predicts the landing and brakes *proportionally* (full back-wish removes 3 m/s in ONE tick and stopped every jump dead).
- `wait` — hold until `WoCourse.path_clear` says the run to the next point meets no hazard: exact, because the hazards are functions of the tick. Walk only the last 1.6 m into a stop point (walking 2.5 m walked the bot through the ram it had timed at a run).
- `board` — something to land on: hold until it will be under the landing and within 5 m; then run and jump at whatever edge comes first (`supported` 0.7 m ahead), but step a gap a stride crosses (jumping the 30 cm to a mover carried the bot over it). `ride` — a point ON a carrier is reached by standing on any carrier (chasing the mover's start coordinates walked the bot off its tail).
- `_bot_hop` jumps an arm due in 0.2–0.4 s along the heading; `_bot_unstick` jumps after a second of going nowhere, or lets go on a face too steep to jump from (a turning log's steep side was a 30-second treadmill).

`bot_fumble_chance` misses a jump per bot, waypoint and round, reproducibly.

## Validating

```bash
godot --headless --path . --import
find . -name '*.gd' -not -path './.godot/*' -not -path './addons/*' | while read f; do
    godot --headless --path . --check-only --script "res://${f#./}"; done
godot --headless --path . res://examples/headless_run.tscn       # 82 checks
godot --headless --path . res://examples/headless_courses.tscn   # every course run by a stand-in, every arena stood in
godot --headless --path . res://examples/headless_net.tscn       # 10 sections, 45 checks
godot --headless --path . res://examples/dedicated.tscn          # 6 sections, 23 checks
godot --headless --path . res://tools/trace_course.tscn -- --course=wo_log_roll --every=0.5
tools/shot.sh --view=course --wo-course-ids=wo_grand_tour
tools/shot.sh --view=finale
```

`headless_courses` drives ticks **without** waiting on physics frames (ten courses at real time is half an hour; it takes ~30 s) — legitimate only because every moving piece is a static body written straight into the physics server. All suites free the previous world before building the next: every world is a child of the suite, they share one physics space, and every course is built at the origin — a world left standing kept its closed start gate exactly where the next runner had to go, which read as the gate never dropping.

Armed so far: `headless_net`'s obstacle agreement (above) and every suite's CHECKS total. Not yet armed one by one: the rest. That is honest, and it is the first thing to do before trusting a new check.

## What running it found

- **The gate never dropped** (in the suite only): a previous world's gate in the same physics space. See Validating.
- **A kinematic body moves a step late**; moving pieces are static bodies now (Decision 1).
- **A restart at the side of the start pad walked off the narrower run-out.** Full-row seats for restarts and joiners, and every route starts at the middle of the pad.
- **The pendulums swung along the path, not across it** (`yaw` 90 turns the swing plane onto Z), so a hammer lifted a waiting bot again and again. Courses use `yaw` 0.
- **The belt on a ramp was a wall**: laid flat at the ramp's middle height. A conveyor takes `pitch` now, and its carry follows it.
- **Hammers 3.2 m apart and rams 3.5 m apart left nowhere to wait**: the one behind reached a person waiting for the one in front. 4.2 m and 4.5 m, waiting halfway / 2.4 m short.
- **Glossy water is the sky.** The first render had no horizon; the water is darker and matte.
- **Ducking every arm broke the pendulums.** A bot that crouched for anything at head height crouched under hammers it should have run past. It ducks only when `WoCourse.high_arm_near` finds an arm whose underside is above a standing jump, and otherwise hops at 0.2–0.4 s as before.

## Delivery: the courses are a second pack

The game's pack does not contain `courses/` (a link, excluded in dot-server-deploy's `pack.json`). mg-wipeout-maps is published as a pack of its own and named in `game.yml` under `server_dependencies`, which dot-server mounts on the server only. `WoModule._add_delivered_courses` asks the game manager for `current_server_dependencies()` and adds each mount's `courses/` to the catalogue before `world.start()`; `WoGame.start()` rebuilds the warmup course only if the catalogue still offers it. **The other option was copying the documents into the game's pack at release, and it loses**: a new course would then be a game release and a shell rebuild for every server, where as a separate pack it is a release of a JSON repository. A server with no maps pack plays `wo_practice` and logs it, which is what `dot-server-deploy/examples/wipeout_client.tscn` exists to catch (26 checks; seven fail with the dependency removed).

## Tells

- **A drop-tile is red for `WoCourse.TILE_WARN_SECONDS` (0.6 s) before it drops**, computed from the tick like everything else (`tile_warning`), so both ends agree about it. `tools/shot.sh --view=tiles` draws it.
- **A high arm is ducked**: The Sweeper's last section is a `high_sweeper` whose arms pass above a crouch and below a standing head.

## Still to do

In the order they are worth doing.

1. **Put it live.** Create `gamemann/mg-wipeout` and `gamemann/mg-wipeout-maps` on GitHub, push, tag both (maps first: the game's `server_dependencies` is pinned at install), and add `wipeout` to a server's `TMC_GAMES`. Not done here because publishing and pushing are the owner's call.
2. **A world model in a watcher's hands**, as mg-smash-copter's list says, and a figure holding a carried prop.
3. **Sounds for the machinery**: an arm's whoosh, a ram's thump, and a sound to go with a tile's red warning.
4. **Course levels for the nightly quota** — see mg-wipeout-maps' CLAUDE.md for what a level is here.
