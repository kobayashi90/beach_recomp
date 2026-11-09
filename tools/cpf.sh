#!/bin/bash
export MG_HARNESS=1  # marks this as a measurement instance; killgame.sh refuses to touch an unmarked one
# cpf.sh LABEL [SECONDS] [extra args...]
#
# Per-second host *CPU-thread cycles per guest frame* for the CPU thread.
#
# This is the yardstick that actually decides the frame rate, and unlike work.sh
# it needs no correction for the emulator's own speed readout:
#
#   at 50 fps on a ~4.1 GHz core the CPU thread has 82 M host cycles per guest
#   frame to spend. A second whose cycles/frame exceeds that cannot be a 50 fps
#   second no matter how idle the rest of the box is. A second under it only
#   needs the thread to actually get the core (preemption is pace.sh's job).
#
# Dividing by the guest frame counter rather than by wall time cancels the
# run-to-run speed wobble that makes raw instruction counts noisy: a run that
# goes 4 % faster covers 4 % more frames and spends 4 % more cycles.
#
# It reports the *distribution*, not just the mean, because the goal is "no dips":
# what matters is the worst second, and how many seconds clear the budget.
set -u

DIR=/home/lain/opencode/beach_recomp
LABEL=${1:?usage: cpf.sh LABEL [seconds] [extra args...]}
DUR=${2:-12}
shift 2 2>/dev/null || shift 1

SO=${MODULE:-$(ls -d "$DIR"/build/modules/GBSP8P/*/gGBSP8P_recomp.so 2>/dev/null | head -1)}
[ -z "$SO" ] && { echo "no module .so"; exit 1; }

"$DIR/tools/killgame.sh" >/dev/null || { echo "cannot free the emulator slot"; exit 1; }
sleep 1

AUTO=$(mktemp -d /tmp/mgcpf-XXXXXX)
LOG="$DIR/logs/cpf-${LABEL}-$(date +%H%M%S).log"
ROWS=$(mktemp /tmp/mgcpf-rows-XXXXXX)

frame_count() { sed -n 's/^frame_count=//p' "$AUTO/status.txt" | head -1; }
status_of()   { sed -n "s/^$1=//p" "$AUTO/status.txt" | head -1; }

cd "$DIR" || exit 1
# shellcheck disable=SC2086
setsid nohup ./lib/ModernGekko/build/moderngekko-run \
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

for i in $(seq 1 "$DUR"); do
  f0=$(frame_count)
  out=$("$DIR/tools/ipc" "$CPU_TID" 1)
  f1=$(frame_count)
  cyc=$(echo "$out" | sed -n 's/.*cycles \([0-9.]*\) G.*/\1/p')
  [ -z "$cyc" ] && continue
  la=$(cut -d' ' -f1 /proc/loadavg)
  run=$(cut -d' ' -f4 /proc/loadavg | cut -d/ -f1)
  echo "$i $f0 $f1 $cyc $(status_of fps) $(status_of speed) $la $run" >>"$ROWS"
done

"$DIR/tools/killgame.sh" >/dev/null

awk -v lbl="$LABEL" -v dur="$DUR" -v envi="$LOG" '
{
  df = $3 - $2;
  if (df <= 0) next;
  cpf = $4 * 1000.0 / df;
  n++;
  v[n] = cpf; fpsv[n] = df; spd[n] = $6;
  sum += cpf; fps_sum += df;
  if (n == 1 || cpf > worst) { worst = cpf; worst_t = $1 }
  if (n == 1 || cpf < best) { best = cpf; best_t = $1 }
  if (cpf > 82.0) over++;
  la_sum += $7 + 0; if ($7 + 0 > la_max) la_max = $7 + 0;
  if ($8 + 0 > run_max) run_max = $8 + 0;
}
END {
  if (!n) { printf "=== %s ===\n  no usable samples\n", lbl; exit }
  # insertion sort for percentiles (n is small)
  for (i = 2; i <= n; i++) { k = v[i]; for (j = i - 1; j >= 1 && v[j] > k; j--) v[j+1] = v[j]; v[j+1] = k }
  p50 = v[int((n + 1) * 0.50)]; p90 = v[int((n + 1) * 0.90)];
  p95 = v[int((n + 1) * 0.95) > n ? n : int((n + 1) * 0.95)];
  printf "=== %s (%d seconds, %d frames) ===\n", lbl, n, fps_sum;
  printf "  Mcycles/frame  mean %6.2f  p50 %6.2f  p90 %6.2f  p95 %6.2f  worst %6.2f (t=%d)\n",
         sum / n, p50, p90, p95, worst, worst_t;
  printf "  budget 82.0 Mcycles  ->  %d of %d seconds over budget", over, n;
  if (over) printf "  (worst second implies %.1f fps)\n", 4100.0 / worst;
  else printf "  (all clear; worst second implies %.1f fps)\n", 4100.0 / worst;
  printf "  mean fps %.2f   speed at end %s\n", fps_sum / dur, spd[n];
  printf "  ambient load   mean %5.2f  max %5.2f   runnable max %d\n", la_sum / n, la_max, run_max;
  printf "  log: %s\n", envi;
}' "$ROWS"
rm -f "$ROWS"
