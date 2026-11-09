#!/bin/bash
export MG_HARNESS=1  # marks this as a measurement instance; killgame.sh refuses to touch an unmarked one
# intro.sh LABEL [SECONDS]
#
# Boots the emulator and samples the automation status file once per second from
# the moment it appears, then prints the per-second trace plus a summary. This
# covers the part of the boot that `speed.sh` deliberately warms past: the
# opening 3D sequence is the heaviest content in the game and the only part that
# drops below real time, so it needs its own measurement or it is invisible.
#
# Environment:
#   MG_ENV    extra environment assignments (e.g. "MODERNGEKKO_PRESENT_MODE=fifo")
#   MG_NICE   niceness for the emulator (negative values need a primed sudo)
#   MG_ARGS   extra launcher arguments
#
# The XFB is read back from status.txt, not by screenshot: in dual-core mode the
# automation screenshot returns a stale XFB, so it cannot judge this content.
set -u

DIR=/home/lain/opencode/beach_recomp
LABEL=${1:?usage: intro.sh LABEL [SECONDS]}
DUR=${2:-60}

SO=${MODULE:-$(ls -d "$DIR"/build/modules/GBSP8P/*/module-build/gGBSP8P_recomp.so 2>/dev/null | head -1)}
[ -z "$SO" ] && { echo "no module .so"; exit 1; }

"$DIR/tools/killgame.sh" >/dev/null || { echo "cannot free the emulator slot"; exit 1; }
sleep 1

AUTO=$(mktemp -d /tmp/mgintro-XXXXXX)
mkdir -p "$AUTO/commands"
LOG="$DIR/logs/intro-${LABEL}-$(date +%H%M%S).log"
cd "$DIR" || exit 1

LAUNCH=(./lib/ModernGekko/build/moderngekko-run
        --game extracted/beach --module "$SO" --wayland --automation-dir "$AUTO")
# shellcheck disable=SC2086
if [ -n "${MG_NICE:-}" ]; then
  # shellcheck disable=SC2086
  setsid nohup env ${MG_ENV:-} sudo -n nice -n "$MG_NICE" "${LAUNCH[@]}" \
    >"$LOG" 2>&1 </dev/null &
else
  # shellcheck disable=SC2086
  setsid nohup env ${MG_ENV:-} "${LAUNCH[@]}" >"$LOG" 2>&1 </dev/null &
fi

for _ in $(seq 1 40); do
  [ -f "$AUTO/status.txt" ] && break
  sleep 1
done
if [ ! -f "$AUTO/status.txt" ]; then
  echo "$LABEL: never booted (see $LOG)"
  "$DIR/tools/killgame.sh" >/dev/null
  exit 1
fi

PID=$(pgrep -x moderngekko-run | head -1)
HZ=$(getconf CLK_TCK)
CT=""
for t in "/proc/$PID/task"/*; do
  [ "$(cat "$t/comm" 2>/dev/null)" = "CPU thread" ] && CT=${t##*/}
done
[ -n "$CT" ] && PREV=$(awk '{print $14+$15}' "/proc/$PID/task/$CT/stat") || PREV=0

printf '%4s %7s %7s %6s %6s %8s\n' t speed fps cpu% load frames ratio
declare -a SPEEDS=()
SECS=0
CPU_HI=0
for i in $(seq 1 "$DUR"); do
  sleep 1
  sp=$(sed -n 's/^speed=//p' "$AUTO/status.txt" | head -1)
  fp=$(sed -n 's/^fps=//p' "$AUTO/status.txt" | head -1)
  fc=$(sed -n 's/^frame_count=//p' "$AUTO/status.txt" | head -1)
  pc=$(sed -n 's/^present_count=//p' "$AUTO/status.txt" | head -1)
  [ -z "$sp" ] && continue
  SECS=$((SECS + 1))
  SPEEDS+=("$sp")
  cpu=0
  if [ -n "$CT" ] && [ -e "/proc/$PID/task/$CT/stat" ]; then
    CUR=$(awk '{print $14+$15}' "/proc/$PID/task/$CT/stat")
    cpu=$(( (CUR - PREV) * 100 / HZ ))
    PREV=$CUR
    [ "$cpu" -ge 90 ] && CPU_HI=$((CPU_HI + 1))
  fi
  ratio=""
  [ -n "$fc" ] && [ -n "$pc" ] && [ "$fc" -gt 0 ] && ratio=$(awk -v p="$pc" -v f="$fc" 'BEGIN{printf "%.2f", p/f}')
  printf '%4d %7s %7s %6d %6s %8s %6s\n' "$i" "$sp" "$fp" "$cpu" \
    "$(cut -d' ' -f1 /proc/loadavg)" "$fc" "$ratio"
done

"$DIR/tools/killgame.sh" >/dev/null

echo
awk -v label="$LABEL" -v hi="$CPU_HI" -v secs="$SECS" '
  { v[NR]=$1+0; s+=$1; n++; if (v[NR]<mn || n==1) mn=v[NR]; if (v[NR]>mx) mx=v[NR]
    if ($1+0 < 0.90) slow++ }
  END {
    if (n == 0) { print label ": no samples"; exit }
    printf "%-18s samples=%d mean=%.4f min=%.4f max=%.4f  below0.90=%d (%d%%)  cpu>=90%%=%d/%d\n",
           label, n, s/n, mn, mx, slow, slow*100/n, hi, secs
  }' <<<"$(printf '%s\n' "${SPEEDS[@]}")"
echo "log: $LOG"
