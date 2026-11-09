#!/bin/bash
export MG_HARNESS=1  # marks this as a measurement instance; killgame.sh refuses to touch an unmarked one
# comb.sh LABEL [SECONDS_BEFORE] [COUNT]
#
# Boots the game, lets it reach moving content, then asks the automation
# protocol for a burst of framebuffer screenshots. /tmp/comb.py scores them for
# vertical combing: stitched interlaced fields make every other row disagree
# with its neighbour, which is the physical signature of "flicker in some
# scenes". Progressive (single-field) output should score near 1.0.
#
# Runs one instance only, like every other harness here.
set -u
DIR=/home/lain/opencode/beach_recomp
LABEL=${1:?usage: comb.sh LABEL [seconds_before] [count]}
DELAY=${2:-12}
COUNT=${3:-6}

SO=${MODULE:-$(ls -d "$DIR"/build/modules/GBSP8P/*/*/gGBSP8P_recomp.so 2>/dev/null | head -1)}
[ -z "$SO" ] && { echo "no module .so"; exit 1; }

"$DIR/tools/killgame.sh" >/dev/null || { echo "cannot free the emulator slot"; exit 1; }
sleep 1

AUTO=$(mktemp -d /tmp/mgcomb-XXXXXX)
OUT=$(mktemp -d /tmp/mgcomb-out-XXXXXX)
mkdir -p "$AUTO/commands"
LOG="$DIR/logs/comb-${LABEL}-$(date +%H%M%S).log"
cd "$DIR" || exit 1

setsid nohup ./lib/ModernGekko/build/moderngekko-run \
  --game extracted/beach --module "$SO" --wayland --automation-dir "$AUTO" \
  >"$LOG" 2>&1 </dev/null &

for _ in $(seq 1 30); do
  [ -f "$AUTO/status.txt" ] && break
  sleep 1
done
[ -f "$AUTO/status.txt" ] || { echo "$LABEL: never booted (see $LOG)"; "$DIR/tools/killgame.sh" >/dev/null; exit 1; }

sleep "$DELAY"
for i in $(seq 1 "$COUNT"); do
  printf 'command=screenshot\npath=%s/%02d.png\n' "$OUT" "$i" >"$AUTO/commands/1$(printf %02d "$i")-shot.txt"
  sleep 0.35
done
for _ in $(seq 1 20); do
  got=$(ls "$OUT"/*.png 2>/dev/null | wc -l)
  [ "$got" -ge "$COUNT" ] && break
  sleep 1
done

SPEED=$(sed -n 's/^speed=//p' "$AUTO/status.txt" | head -1)
"$DIR/tools/killgame.sh" >/dev/null
echo "$LABEL: speed=$SPEED frames=$(ls "$OUT"/*.png 2>/dev/null | wc -l) log=$LOG"
python3 /tmp/comb.py "$OUT/*.png"
