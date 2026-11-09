#!/bin/bash
export MG_HARNESS=1  # marks this as a measurement instance; killgame.sh refuses to touch an unmarked one
# measure.sh LABEL [sample_seconds] [perfcount_seconds]
#
# Launches ModernGekko with the Beach Spikers module, samples the window-title
# FPS once a second, runs tools/perfcount against the process for a window, then
# stops the game cleanly so the [staticrecomp] shutdown stats land in the log.
#
# Prints, on one screen:
#   avg/min/max FPS over the sampling window (first 20 s discarded as warmup)
#   cycles / instructions / IPC measured by perfcount
#   the shutdown stats line (native/fallback/hook_fb/fb_fast/fb_slow)
set -u

DIR=/home/lain/opencode/beach_recomp
LABEL=${1:?usage: measure.sh LABEL [sample_seconds] [perfcount_seconds]}
DUR=${2:-120}
PCDUR=${3:-60}
WARMUP=${WARMUP:-20}

# MODULE overrides the built module, for A/B against a saved .so.
SO=${MODULE:-$(ls -d "$DIR"/build/modules/GBSP8P/*/gGBSP8P_recomp.so 2>/dev/null | head -1)}
if [ -z "$SO" ]; then echo "no module .so found"; exit 1; fi
if pgrep -x moderngekko-run >/dev/null; then echo "a game is already running; stop it first"; exit 1; fi

STAMP=$(date +%H%M%S)
LOG="$DIR/logs/mg-${STAMP}-${LABEL}.log"

cd "$DIR" || exit 1
# GRAPHICS selects the video backend (see --graphics in --help); EXTRA appends
# any other launcher flag. Both are empty by default so the run matches a plain
# manual launch.
GRAPHICS=${GRAPHICS:-}
EXTRA=${EXTRA:-}
# shellcheck disable=SC2086
"$DIR/tools/killgame.sh" >/dev/null || { echo "cannot free the emulator slot"; exit 1; }
sleep 1
setsid nohup ./lib/ModernGekko/build/moderngekko-run \
  --game extracted/beach --module "$SO" --wayland \
  ${GRAPHICS:+--graphics $GRAPHICS} $EXTRA >"$LOG" 2>&1 </dev/null &
echo "launched, log: $LOG"

# wait for the window to exist
WID=""
for _ in $(seq 1 60); do
  WID=$(kdotool search --name "FPS" 2>/dev/null | head -1)
  [ -n "$WID" ] && break
  sleep 1
done
if [ -z "$WID" ]; then echo "window never appeared (see $LOG)"; exit 1; fi
echo "window $WID: $(kdotool getwindowname "$WID" 2>/dev/null)"

PID=$(pgrep -x moderngekko-run | head -1)
echo "pid $PID"

# perfcount in the background, starting after warmup
( [ "$PCDUR" -gt 0 ] && sleep "$WARMUP" && "$DIR/tools/perfcount" "$PID" "$PCDUR" \
    >"$DIR/logs/perf-${STAMP}-${LABEL}.txt" 2>&1 ) &
PCPID=$!

FPSFILE="$DIR/logs/fps-${STAMP}-${LABEL}.txt"
: >"$FPSFILE"

# Per-thread CPU attribution: the emulator spends its wall clock either running
# guest code (CPU thread) or waiting for the rasterizer (GPU thread), and which
# one is saturated decides whether more recompiler work can help at all.
THREADS0=$(mktemp)
for t in $(ls /proc/$PID/task 2>/dev/null); do
  n=$(awk '{print $14+$15}' "/proc/$PID/task/$t/stat" 2>/dev/null) || continue
  printf '%s %s %s\n' "$t" "${n:-0}" "$(cat "/proc/$PID/task/$t/comm" 2>/dev/null)" >>"$THREADS0"
done

for _ in $(seq 1 "$DUR"); do
  t=$(kdotool getwindowname "$WID" 2>/dev/null)
  case "$t" in
    *FPS*) printf '%s\n' "${t##*| }" | tr -d ' FPS' >>"$FPSFILE" ;;
  esac
  sleep 1
done
wait $PCPID 2>/dev/null

echo
echo "-------- thread CPU seconds over ${DUR}s (top 6) --------"
for t in $(ls /proc/$PID/task 2>/dev/null); do
  n=$(awk '{print $14+$15}' "/proc/$PID/task/$t/stat" 2>/dev/null) || continue
  base=$(awk -v t="$t" '$1 == t {print $2}' "$THREADS0")
  comm=$(cat "/proc/$PID/task/$t/comm" 2>/dev/null)
  [ -n "$base" ] && [ -n "$n" ] && echo "$((n - base)) $comm"
done | sort -rn | head -6 | awk '{printf "  %-6.2fs  %s\n", $1/100, $2}'
rm -f "$THREADS0"

# Never leave an instance behind: a survivor splits the present path and looks
# exactly like a frame-rate wall.
"$DIR/tools/killgame.sh" >/dev/null

echo
echo "================= RESULT [$LABEL] ================="
awk -v w="$WARMUP" '
  { n++; if (n > w && $1 != "") { s += $1; c++; if (min == "" || $1 < min) min = $1; if ($1 > max) max = $1 } }
  END { if (c > 0) printf "fps  avg=%.2f  min=%.2f  max=%.2f  (n=%d)\n", s/c, min, max, c; else print "fps  no samples" }
' "$FPSFILE"
cat "$DIR/logs/perf-${STAMP}-${LABEL}.txt" 2>/dev/null | grep -E "seconds|threads|cycles|instructions|branches|IPC"
grep -E "\[staticrecomp\] (shutdown|dispatch-site|fallback-word)" "$LOG" | head -40
echo "raw: $FPSFILE  $LOG"
