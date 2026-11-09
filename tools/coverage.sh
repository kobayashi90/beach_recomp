#!/bin/bash
export MG_HARNESS=1  # marks this as a measurement instance; killgame.sh refuses to touch an unmarked one
# coverage.sh LABEL [SECONDS] [extra launcher args...]
#
# Drives the emulator through randomised input to widen the *runtime* entry set
# that prune_dispatch.py unions in. The static entry set cannot be complete:
# `blr` returns the pc through a guest stack slot and `bctr` jumps through a
# guest table, so the address the chassis next dispatches to is not visible in
# the chunk text. The pruner therefore ships `--default-fallback` (interpret one
# instruction, re-dispatch) and the misses it reports are exactly the addresses
# this run exists to collect.
#
# With STATICRECOMP_ENTRY_LOG the module dispatcher records every address it is
# handed, which is the set the pruned switch must contain. This script also
# greps the run for `[entrymiss]` lines so a pruned build can add them back.
#
# Input is seeded, so the same LABEL + SEED replays the same exploration.
#
# Environment:
#   SEED   bash RANDOM seed (default 1)
#   REGION disc id to profile (default GBSP8P = PAL); GAME/MODULE override it
#   MODULE module .so to load (default: the built one for REGION)
set -u

DIR=/home/lain/opencode/beach_recomp
LABEL=${1:?usage: coverage.sh LABEL [SECONDS] [extra args...]}
DUR=${2:-120}
shift 2 2>/dev/null || shift 1

REGION=${REGION:-GBSP8P}
if [ -z "${GAME:-}" ] || [ -z "${MODULE:-}" ]; then
  case "$REGION" in
    GBSP8P) def_game=$DIR/extracted/beach ;;
    GBSE8P) def_game=$DIR/extracted/beach-us ;;
    *)      def_game=${GAME:?set GAME and MODULE for unknown region $REGION} ;;
  esac
  def_so=$(ls -d "$DIR"/build/modules/"$REGION"/*/module-build/g"${REGION}"_recomp.so 2>/dev/null | head -1)
fi
GAME_DIR=${GAME:-${def_game:?no module .so for region $REGION}}
SO=${MODULE:-${def_so:-}}
[ -z "$SO" ] && { echo "no module .so"; exit 1; }
[ -d "$GAME_DIR" ] || { echo "no game dir: $GAME_DIR"; exit 1; }

"$DIR/tools/killgame.sh" >/dev/null || { echo "cannot free the emulator slot"; exit 1; }
sleep 1

AUTO=$(mktemp -d /tmp/mgcov-XXXXXX)
mkdir -p "$AUTO/commands"
STAMP=$(date +%H%M%S)
LOG="$DIR/logs/cov-${LABEL}-${STAMP}.log"
ENTRY="$DIR/logs/cov-${LABEL}-${STAMP}.entries"
cd "$DIR" || exit 1

# shellcheck disable=SC2086
setsid nohup env STATICRECOMP_ENTRY_LOG="$ENTRY" \
  ./lib/ModernGekko/build/moderngekko-run \
  --game "$GAME_DIR" --module "$SO" --wayland --automation-dir "$AUTO" \
  "$@" >"$LOG" 2>&1 </dev/null &

for _ in $(seq 1 40); do
  [ -f "$AUTO/status.txt" ] && break
  sleep 1
done
[ -f "$AUTO/status.txt" ] || { echo "$LABEL: never booted (see $LOG)"; "$DIR/tools/killgame.sh" >/dev/null; exit 1; }

seq=0
send() {  # send NAME FIELD=VALUE...
  local name=$1; shift
  seq=$((seq + 1))
  printf '%s\n' "$@" >"$AUTO/commands/$(printf '%05d' "$seq")-$name.cmd"
}

RANDOM=${SEED:-1}
# The opening screens all advance on Start/A, so hammering those for the first
# stretch gets into a match without needing a per-screen state machine.
sleep 10
for _ in 1 2 3 4 5 6; do
  send "start" "command=pad_frames" "port=0" "frames=8" "start=1"
  sleep 0.6
  send "a" "command=pad_frames" "port=0" "frames=8" "a=1"
  sleep 0.6
done

t=0
while [ "$t" -lt "$DUR" ]; do
  # Movement + a spike button: the stick swings are what reach the character,
  # ball-physics and camera code paths, which is where the computed jumps live.
  mx=$(awk -v r=$((RANDOM % 201 - 100)) 'BEGIN { printf "%.2f", r / 100 }')
  my=$(awk -v r=$((RANDOM % 201 - 100)) 'BEGIN { printf "%.2f", r / 100 }')
  cx=$(awk -v r=$((RANDOM % 201 - 100)) 'BEGIN { printf "%.2f", r / 100 }')
  cy=$(awk -v r=$((RANDOM % 201 - 100)) 'BEGIN { printf "%.2f", r / 100 }')
  send "move" "command=pad_frames" "port=0" "frames=20" \
    "main_x=$mx" "main_y=$my" "c_x=$cx" "c_y=$cy"
  case $((RANDOM % 4)) in
    0) send "btn-a" "command=pad_frames" "port=0" "frames=6" "a=1" ;;
    1) send "btn-b" "command=pad_frames" "port=0" "frames=6" "b=1" ;;
    2) send "btn-z" "command=pad_frames" "port=0" "frames=6" "z=1" ;;
    3) send "btn-l" "command=pad_frames" "port=0" "frames=6" "l=1" ;;
  esac
  sleep 1
  t=$((t + 1))
done

send "stop" "command=stop"
sleep 3
"$DIR/tools/killgame.sh" >/dev/null

echo "=== coverage [$LABEL] ==="
if [ -s "$ENTRY" ]; then
  sort -u "$ENTRY" >"$ENTRY.sorted"
  echo "entry log: $(wc -l <"$ENTRY.sorted") distinct addresses -> $ENTRY.sorted"
else
  echo "entry log: EMPTY (module did not dump; see $LOG)"
fi
miss=$(grep -o 'entrymiss\] pc=[0-9A-F]*' "$LOG" 2>/dev/null | sed 's/.*pc=//' | sort -u)
if [ -n "$miss" ]; then
  echo "entry misses (${LABEL}):"
  printf '%s\n' "$miss"
  printf '%s\n' "$miss" >"$ENTRY.miss"
  echo "written to $ENTRY.miss"
else
  echo "entry misses: none"
fi
echo "log: $LOG"
