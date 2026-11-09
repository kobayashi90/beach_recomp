#!/bin/bash
export MG_HARNESS=1  # marks this as a measurement instance; killgame.sh refuses to touch an unmarked one
# shotseq.sh LABEL FRAME_START STEP COUNT [extra launcher args...]
#
# Capture COUNT screenshots, STEP guest frames apart, starting at FRAME_START.
# Guest frame counts are the only clock that lines two runs up when they run at
# different speeds, and a single pair can miss by a frame or two, so take a
# small window and let the comparator pick the best match.
#
# Files: logs/seq-<label>-<frame>.png
set -u

DIR=/home/lain/opencode/beach_recomp
LABEL=${1:?usage: shotseq.sh LABEL FRAME_START STEP COUNT [args...]}
START=${2:?}
STEP=${3:?}
COUNT=${4:?}
shift 4
DELAY=${DELAY:-6}

SO=${MODULE:-$(ls -d "$DIR"/build/modules/GBSP8P/*/gGBSP8P_recomp.so 2>/dev/null | head -1)}
[ -z "$SO" ] && { echo "no module .so"; exit 1; }

"$DIR/tools/killgame.sh" >/dev/null || { echo "cannot free the emulator slot"; exit 1; }
sleep 1

AUTO=$(mktemp -d /tmp/mgseq-XXXXXX)
mkdir -p "$AUTO/commands"
LOG="$DIR/logs/seq-${LABEL}-$(date +%H%M%S).log"
cd "$DIR" || exit 1
rm -f logs/seq-"$LABEL"-*.png

# shellcheck disable=SC2086
setsid nohup ./lib/ModernGekko/build/moderngekko-run \
  --game extracted/beach --module "$SO" --wayland --automation-dir "$AUTO" \
  "$@" >"$LOG" 2>&1 </dev/null &

for _ in $(seq 1 25); do
  [ -f "$AUTO/status.txt" ] && break
  sleep 1
done
if [ ! -f "$AUTO/status.txt" ]; then
  echo "$LABEL: never booted (see $LOG)"
  "$DIR/tools/killgame.sh" >/dev/null
  exit 1
fi
sleep "$DELAY"

n=0
for i in $(seq 0 $((COUNT - 1))); do
  target=$((START + i * STEP))
  for _ in $(seq 1 2000); do
    f=$(sed -n 's/^frame_count=//p' "$AUTO/status.txt" | head -1)
    [ -n "$f" ] && [ "$f" -ge "$target" ] && break
    sleep 0.02
  done
  n=$((n + 1))
  printf 'command=screenshot\npath=%s/logs/seq-%s-%03d.png\n' "$DIR" "$LABEL" "$target" \
    >"$AUTO/commands/$(printf '%03d' "$n")-shot.txt"
  # Give the runtime time to service the command before queueing the next one.
  for _ in $(seq 1 100); do
    [ -s "logs/seq-${LABEL}-$(printf '%03d' "$target").png" ] && break
    sleep 0.05
  done
done

sleep 1
SPEED=$(sed -n 's/^speed=//p' "$AUTO/status.txt" | head -1)
"$DIR/tools/killgame.sh" >/dev/null
echo "$LABEL: $(ls logs/seq-"$LABEL"-*.png 2>/dev/null | wc -l) frames captured, speed=$SPEED"
