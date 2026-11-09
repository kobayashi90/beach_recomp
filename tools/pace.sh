#!/bin/bash
export MG_HARNESS=1  # marks this as a measurement instance; killgame.sh refuses to touch an unmarked one
# pace.sh LABEL [SECONDS]
#
# What the *display* gets, per second, while the emulator runs a fixed window.
#
# `speed` alone cannot tell "we are slow" apart from "we are producing frames
# but not presenting them". status.txt exposes frame_count (guest VI frames) and
# present_count (actual presents), so their per-second deltas answer that
# directly, and the ratio is the frame-drop rate that is visible to a player.
#
# Also reports instantaneous per-thread CPU of the emulator process (ps reports
# a lifetime average, which is useless after a 30 minute build).
set -u

DIR=/home/lain/opencode/beach_recomp
LABEL=${1:?usage: pace.sh LABEL [seconds] [extra args...]}
DUR=${2:-12}
shift 2 2>/dev/null || shift 1

SO=${MODULE:-$(ls -d "$DIR"/build/modules/GBSP8P/*/gGBSP8P_recomp.so 2>/dev/null | head -1)}
[ -z "$SO" ] && { echo "no module .so"; exit 1; }

"$DIR/tools/killgame.sh" >/dev/null || { echo "cannot free the emulator slot"; exit 1; }
sleep 1

AUTO=$(mktemp -d /tmp/mgpace-XXXXXX)
LOG="$DIR/logs/pace-${LABEL}-$(date +%H%M%S).log"
cd "$DIR" || exit 1
setsid nohup ./lib/ModernGekko/build/moderngekko-run \
  --game extracted/beach --module "$SO" --wayland --automation-dir "$AUTO" \
  "$@" >"$LOG" 2>&1 </dev/null &

for _ in $(seq 1 40); do
  [ -f "$AUTO/status.txt" ] && break
  sleep 1
done
[ -f "$AUTO/status.txt" ] || { echo "$LABEL: never booted (see $LOG)"; "$DIR/tools/killgame.sh" >/dev/null; exit 1; }

PID=$(pgrep -x moderngekko-run | head -1)
echo "  pid=$PID   log=$LOG"
sleep "${WARMUP:-8}"

get() { sed -n "s/^$1=//p" "$AUTO/status.txt" | head -1; }

echo "   t    fps    vps  speed    dframe   dpres  ratio   cpu%   vid%"
prev_f=$(get frame_count); prev_p=$(get present_count)
clk=$(getconf CLK_TCK)
prev_t=0
prev_cpu=0; prev_vid=0
for i in $(seq 1 "$DUR"); do
  sleep 1
  f=$(get frame_count); p=$(get present_count)
  df=$((f - prev_f)); dp=$((p - prev_p))
  # instantaneous thread utilisation from /proc/<pid>/task/*/stat utime+stime
  tot=0; cpu=0; vid=0
  for t in /proc/"$PID"/task/*/; do
    read -r -a st < "$t/stat" 2>/dev/null || continue
    c=$(cat "$t/comm" 2>/dev/null)
    ticks=$(( ${st[13]} + ${st[14]} ))
    tot=$((tot + ticks))
    case "$c" in "CPU thread"*) cpu=$((cpu + ticks)) ;; "Video thread"*) vid=$((vid + ticks)) ;; esac
  done
  if [ "$prev_t" -gt 0 ]; then
    cpu_pct=$(( (cpu - prev_cpu) * 100 / clk ))
    vid_pct=$(( (vid - prev_vid) * 100 / clk ))
  else
    cpu_pct=-; vid_pct=-
  fi
  prev_t=1; prev_cpu=$cpu; prev_vid=$vid; prev_f=$f; prev_p=$p
  if [ "$dp" -gt 0 ]; then ratio=$(awk -v a="$df" -v b="$dp" 'BEGIN{printf "%.2f", a/b}'); else ratio=-; fi
  printf '%4d %6s %6s %6s %8d %7d %6s %6s %6s\n' \
    "$i" "$(get fps)" "$(get vps)" "$(get speed)" "$df" "$dp" "$ratio" "$cpu_pct" "$vid_pct"
done

"$DIR/tools/killgame.sh" >/dev/null
