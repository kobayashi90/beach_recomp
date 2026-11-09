#!/bin/bash
export MG_HARNESS=1  # marks this as a measurement instance; killgame.sh refuses to touch an unmarked one
# shot.sh LABEL [extra launcher args...]
#
# Boot the emulator exactly like speed.sh does, let it warm up, then ask the
# automation protocol for a screenshot of the framebuffer and stop. This is how
# we check that a change did not break rendering: the PNG comes from the
# emulator's own present path, so it cannot be fooled by a compositor overlay
# (and grim cannot capture at all on this KWin session).
set -u

DIR=/home/lain/opencode/beach_recomp
LABEL=${1:?usage: shot.sh LABEL [extra args...]}
shift
DELAY=${DELAY:-14}

SO=${MODULE:-$(ls -d "$DIR"/build/modules/GBSP8P/*/gGBSP8P_recomp.so 2>/dev/null | head -1)}
[ -z "$SO" ] && { echo "no module .so"; exit 1; }

"$DIR/tools/killgame.sh" >/dev/null || { echo "cannot free the emulator slot"; exit 1; }
sleep 1

AUTO=$(mktemp -d /tmp/mgshot-XXXXXX)
mkdir -p "$AUTO/commands"
LOG="$DIR/logs/shot-${LABEL}-$(date +%H%M%S).log"
OUT="$DIR/logs/shot-${LABEL}.png"
rm -f "$OUT"
cd "$DIR" || exit 1

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
if [ "${FRAME:-0}" -gt 0 ] 2>/dev/null; then
  # Wall-clock delays cannot line up two runs at different speeds. Wait for the
  # guest's own frame counter so both captures land on the same frame.
  for _ in $(seq 1 400); do
    f=$(sed -n 's/^frame_count=//p' "$AUTO/status.txt" | head -1)
    [ -n "$f" ] && [ "$f" -ge "$FRAME" ] && break
    sleep 0.05
  done
fi
if [ "${PAUSE:-0}" = "1" ]; then
  printf 'command=pause\n' >"$AUTO/commands/009-pause.txt"
  sleep 2
fi
printf 'command=screenshot\npath=%s\n' "$OUT" >"$AUTO/commands/010-shot.txt"
for _ in $(seq 1 15); do
  [ -s "$OUT" ] && break
  sleep 1
done
sleep 1
SPEED=$(sed -n 's/^speed=//p' "$AUTO/status.txt" | head -1)
"$DIR/tools/killgame.sh" >/dev/null

if [ -s "$OUT" ]; then
  echo "$LABEL: $(stat -c%s "$OUT") bytes  speed=$SPEED  -> $OUT"
else
  echo "$LABEL: no screenshot produced (see $LOG)"
  exit 1
fi
