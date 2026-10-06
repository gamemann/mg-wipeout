#!/usr/bin/env bash
# Render the game and look at it. The check no assertion in this repository makes.
#
#   tools/shot.sh                                      # a player's own eyes, a few seconds in
#   tools/shot.sh --view=course --wo-course-ids=wo_spin_cycle   # a course, from above
#   tools/shot.sh --view=start                         # the start pad, from behind the runners
#   tools/shot.sh --view=hazard --seconds=2            # the first thing that throws you, close
#   tools/shot.sh --view=third --seconds=8             # third person, on the course
#   tools/shot.sh --view=arena --arena=wo_arena_pit    # an arena, from above
#   tools/shot.sh --view=finale                        # a real final death, a finisher's eyes
#   tools/shot.sh --view=course --out=res://screenshots/x.png   # any --wo-* is the game's config
#   tools/shot.sh --view=third --board                 # with the Tab scoreboard held open
#
# xvfb-run because this needs a rendering context and the machines this runs on have no
# display. `--headless` is NOT a substitute: it gives a null renderer and saves a frame of
# nothing, which is worse than no screenshot because it looks like one.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p screenshots

view="eyes"
seconds="4"
out=""
# A render wants the round running: no warmup and a short countdown, unless asked otherwise.
# Passed as the game's own flags, because the client reads its configuration as it loads and
# a value changed after that has already been copied into the round's rules.
config=("--wo-warmup-seconds=0" "--wo-countdown-seconds=1")

for arg in "$@"; do
    case "$arg" in
        --view=*)    view="${arg#*=}" ;;
        --seconds=*) seconds="${arg#*=}" ;;
        --out=*)     out="${arg#*=}" ;;
        --wo-*)      config+=("$arg") ;;
        --arena=*)   config+=("$arg") ;;
        --board)     config+=("$arg") ;;
        *)           echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
done

[ -n "$out" ] || out="res://screenshots/${view}.png"

scene="res://tools/shot.tscn"

exec xvfb-run -a "${GODOT:-godot}" --path . --resolution 1280x720 \
    "$scene" -- "--seconds=$seconds" "--view=$view" "--out=$out" "${config[@]}"
