#!/bin/bash
export MG_HARNESS=1  # marks this as a measurement instance; killgame.sh refuses to touch an unmarked one
# profile.sh LABEL [seconds] [extra launcher args...]
#
# Samples the running emulator with tools/profsample (perf_event_open ring
# buffer, 997 Hz) and resolves the IPs to symbols. Use a savestate so every
# profile covers the same content -- profile results are otherwise dominated by
# whatever screen happened to be up (menus run at full speed, 3D gameplay does
# not).
#
# Examples:
#   tools/profile.sh gp-baseline 30 --load-state $PWD/states/gameplay-01.state
#   MODULE=logs/gGBSP8P_recomp-baseline.so tools/profile.sh gp-old 30 \
#       --load-state $PWD/states/gameplay-01.state
#   THREAD=CPU-GPU tools/profile.sh gp 30 --load-state ...   # only that thread
set -u

DIR=/home/lain/opencode/beach_recomp
LABEL=${1:?usage: profile.sh LABEL [seconds] [extra args...]}
DUR=${2:-30}
shift 2 2>/dev/null || shift 1

# The disc and the module are a pair, same as in speed.sh: pointing the
# NTSC-U module at extracted/beach would load the wrong game root. GAME
# defaults to the PAL pair; set both to profile another region, e.g.
#   GAME=$DIR/extracted/beach-us MODULE=$DIR/build/modules/GBSE8P/*/gGBSE8P_recomp.so \
#     tools/profile.sh us-gp 30 --load-state $PWD/states/gameplay-GBSE8P.state
GAME_DIR=${GAME:-$DIR/extracted/beach}
SO=${MODULE:-$(ls -d "$DIR"/build/modules/GBSP8P/*/gGBSP8P_recomp.so 2>/dev/null | head -1)}
[ -z "$SO" ] && { echo "no module .so"; exit 1; }
[ -d "$GAME_DIR" ] || { echo "no game dir: $GAME_DIR"; exit 1; }

"$DIR/tools/killgame.sh" >/dev/null || { echo "cannot free the emulator slot"; exit 1; }
sleep 1

AUTO=$(mktemp -d /tmp/mgprof-XXXXXX)
STAMP=$(date +%H%M%S)
LOG="$DIR/logs/prof-${LABEL}-${STAMP}.log"
SAMPLES="$DIR/logs/prof-${LABEL}-${STAMP}.samples"
MAPS="$DIR/logs/prof-${LABEL}-${STAMP}.maps"
cd "$DIR" || exit 1

# shellcheck disable=SC2086
setsid nohup ./lib/ModernGekko/build/moderngekko-run \
  --game "$GAME_DIR" --module "$SO" --wayland --automation-dir "$AUTO" \
  "$@" >"$LOG" 2>&1 </dev/null &

for _ in $(seq 1 40); do
  [ -f "$AUTO/status.txt" ] && break
  sleep 1
done
[ -f "$AUTO/status.txt" ] || { echo "$LABEL: never booted (see $LOG)"; "$DIR/tools/killgame.sh" >/dev/null; exit 1; }

# Warmup: the first seconds are boot, shader/pipeline creation and (with
# --load-state) state loading, all of which would swamp the real profile.
sleep "${WARMUP:-12}"

PID=$(pgrep -x moderngekko-run | head -1)
[ -z "$PID" ] && { echo "$LABEL: process died during warmup (see $LOG)"; exit 1; }

cp "/proc/$PID/maps" "$MAPS"

# A rebuild relocates every symbol, and resolving old samples against a new
# binary prints confident nonsense. Snapshot our own binaries next to the
# profile and repoint the saved maps at the copies.
python3 "$DIR/tools/profsnap.py" "$MAPS" "$DIR/logs/profile-blobs" \
  "$DIR/" "/home/lain/opencode/beach_recomp/" 2>&1 | sed 's/^/  /'

# Per-thread names, so a tid in the sample list can be read as "CPU-GPU thread".
THREADS="$DIR/logs/prof-${LABEL}-${STAMP}.threads"
: >"$THREADS"
for t in "/proc/$PID/task"/*; do
  printf '%s %s\n' "${t##*/}" "$(cat "$t/comm" 2>/dev/null)" >>"$THREADS"
done

SPEED_BEFORE=$(sed -n 's/^speed=//p' "$AUTO/status.txt" | head -1)
"$DIR/tools/profsample" "$PID" "$DUR" "${HZ:-997}" >"$SAMPLES"
SPEED_AFTER=$(sed -n 's/^speed=//p' "$AUTO/status.txt" | head -1)

"$DIR/tools/killgame.sh" >/dev/null

echo
echo "=============== PROFILE [$LABEL] ==============="
echo "module : $(basename "$SO")"
echo "speed  : $SPEED_BEFORE -> $SPEED_AFTER (samples taken at 997 Hz for ${DUR}s)"
echo
echo "--- per-thread sample counts ---"
awk '{ c[$2] += $1 } END { for (t in c) printf "%8d  %s\n", c[t], t }' "$SAMPLES" | sort -rn | head -8
echo
if [ -n "${THREAD:-}" ]; then
  TID=$(awk -v n="$THREAD" 'index($0, n) { print $1; exit }' "$THREADS")
  if [ -z "$TID" ]; then echo "thread '$THREAD' not found:"; cat "$THREADS"; exit 1; fi
  echo "--- hot symbols inside tid $TID ($THREAD) ---"
  awk -v t="$TID" '$2 == t' "$SAMPLES" >"$SAMPLES.thread"
  python3 "$DIR/tools/profsym.py" "$SAMPLES.thread" "$MAPS" --top "${TOP:-30}"
  rm -f "$SAMPLES.thread"
else
  echo "--- hot symbols (all threads) ---"
  python3 "$DIR/tools/profsym.py" "$SAMPLES" "$MAPS" --top "${TOP:-30}"
fi
echo
echo "log     : $LOG"
echo "samples : $SAMPLES"
echo "maps    : $MAPS"
echo "threads : $THREADS"
