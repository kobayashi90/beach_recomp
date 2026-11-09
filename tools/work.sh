#!/bin/bash
# work.sh LABEL [SECONDS] [extra args...]
#
# Measures *host instructions retired by the CPU thread* over a deterministic
# savestate window, which is the number that decides whether a codegen change
# helped.
#
# Why not just use speed: `speed` moves 3-5 % run to run on this box purely from
# background load (zram swapping, Chrome, Shadow), so a 5 % codegen win is
# invisible in it. The instruction count for the same savestate window is
# reproducible to well under 1 %, so a before/after comparison of it is the only
# honest signal. Speed and IPC are printed alongside because "fewer instructions
# but slower" (denser code hurting IPC) is a real possible outcome.
#
# The window is fixed: WARMUP seconds after the state loads, then SECONDS of
# sampling. Always use the same arguments when comparing builds.
set -u

DIR=/home/lain/opencode/beach_recomp
LABEL=${1:?usage: work.sh LABEL [seconds] [extra args...]}
DUR=${2:-12}
shift 2 2>/dev/null || shift 1

SO=${MODULE:-$(ls -d "$DIR"/build/modules/GBSP8P/*/gGBSP8P_recomp.so 2>/dev/null | head -1)}
[ -z "$SO" ] && { echo "no module .so"; exit 1; }

"$DIR/tools/killgame.sh" >/dev/null || { echo "cannot free the emulator slot"; exit 1; }
sleep 1

AUTO=$(mktemp -d /tmp/mgwork-XXXXXX)
LOG="$DIR/logs/work-${LABEL}-$(date +%H%M%S).log"
cd "$DIR" || exit 1
# shellcheck disable=SC2086
setsid nohup ${PIN:+$PIN} ./lib/ModernGekko/build/moderngekko-run \
  --game extracted/beach --module "$SO" --wayland --automation-dir "$AUTO" \
  "$@" >"$LOG" 2>&1 </dev/null &

for _ in $(seq 1 40); do
  [ -f "$AUTO/status.txt" ] && break
  sleep 1
done
[ -f "$AUTO/status.txt" ] || { echo "$LABEL: never booted (see $LOG)"; "$DIR/tools/killgame.sh" >/dev/null; exit 1; }

PID=$(pgrep -x moderngekko-run | head -1)
CPU_TID=""
for _ in $(seq 1 100); do
  for t in /proc/"$PID"/task/*/; do
    [ "$(cat "$t/comm" 2>/dev/null)" = "CPU thread" ] && CPU_TID=${t%/} && CPU_TID=${CPU_TID##*/}
  done
  [ -n "$CPU_TID" ] && break
  sleep 0.1
done
[ -z "$CPU_TID" ] && { echo "$LABEL: no CPU thread"; "$DIR/tools/killgame.sh" >/dev/null; exit 1; }

sleep "${WARMUP:-8}"

# One reading for the whole window: sums are additive, and a single long sample
# avoids the per-sample overhead skewing the count.
OUT=$("$DIR/tools/ipc" "$CPU_TID" "$DUR")
speed=$(sed -n 's/^speed=//p' "$AUTO/status.txt" | head -1)
"$DIR/tools/killgame.sh" >/dev/null

echo "=== $LABEL (window ${WARMUP:-8}s+${DUR}s) ==="
echo "$OUT" | sed 's/^  //'
echo "  speed at end: ${speed:-?}"
echo "  log: $LOG"
