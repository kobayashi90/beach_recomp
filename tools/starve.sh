#!/bin/bash
export MG_HARNESS=1  # marks this as a measurement instance; killgame.sh refuses to touch an unmarked one
# starve.sh LABEL [SECONDS]
#
# Answers one question: when speed < 1.000, is the CPU thread SATURATED (it gets
# ~100 % of a core and still cannot finish the frame) or STARVED (the scheduler
# hands it less than a core)?
#
# Those two have completely different fixes, and "speed is low" cannot tell them
# apart. This reads the per-thread utime+stime out of /proc and compares it to
# wall clock, so "busy fraction" is measured rather than inferred:
#
#   busy ~1.00  -> saturated: the thread needs less work (codegen/host glue)
#   busy < 0.95 -> starved:   priority / affinity / memory pressure, not work
#
# It also reports page faults and VmSwap, because on this box zram holds tens of
# GB of compressed swap and a reclaim spike looks exactly like a slow scene.
#
# Samples the automation status file for the emulator's own speed number, so the
# two readings are from the same wall-clock window.
set -u

DIR=/home/lain/opencode/beach_recomp
LABEL=${1:?usage: starve.sh LABEL [seconds] [extra args...]}
DUR=${2:-20}
shift 2 2>/dev/null || shift 1

SO=${MODULE:-$(ls -d "$DIR"/build/modules/GBSP8P/*/gGBSP8P_recomp.so 2>/dev/null | head -1)}
[ -z "$SO" ] && { echo "no module .so"; exit 1; }

"$DIR/tools/killgame.sh" >/dev/null || { echo "cannot free the emulator slot"; exit 1; }
sleep 1

AUTO=$(mktemp -d /tmp/mgstarve-XXXXXX)
LOG="$DIR/logs/starve-${LABEL}-$(date +%H%M%S).log"
cd "$DIR" || exit 1
# shellcheck disable=SC2086
# PIN="taskset -c 0,1" confines the process to a cpu set. The scheduler
# otherwise migrates the CPU thread tens of times per second, and each hop costs
# the L2 of a 58 MB module, so pinning is a real experiment, not a hunch.
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
[ -z "$PID" ] && { echo "$LABEL: no pid"; exit 1; }

# The threads are named; find the one that matters most for speed. The emulation
# threads are spawned after the automation status file already exists, so poll
# for a few seconds instead of reading the thread list once.
tid_of() { # tid_of <comm prefix>
  local i t c
  for ((i = 0; i < 100; i++)); do
    for t in /proc/"$PID"/task/*/; do
      c=$(cat "$t/comm" 2>/dev/null)
      case "$c" in
        "$1"*) echo "${t#/proc/$PID/task/}" | tr -d /; return 0 ;;
      esac
    done
    sleep 0.1
  done
  return 1
}
CPU_TID=$(tid_of "CPU thread")
GPU_TID=$(tid_of "Video thread")
[ -z "${CPU_TID:-}" ] && { echo "$LABEL: no CPU thread"; "$DIR/tools/killgame.sh" >/dev/null; exit 1; }

# TID_PIN="1:2" pins the CPU thread to cpu1 and the video thread to cpu2 -- one
# physical core each, no hyper-thread sibling, and no migration. This is the
# experiment that distinguishes "we need more compute" from "the scheduler keeps
# throwing our L2 away". Only these two threads are pinned; everything else in
# the process (audio, asset loaders, shader compilers) stays free to float.
if [ -n "${TID_PIN:-}" ]; then
  cpu_cpu=${TID_PIN%%:*}
  vid_cpu=${TID_PIN##*:}
  taskset -pc "$cpu_cpu" "$CPU_TID" >/dev/null 2>&1 &&
    echo "  pinned CPU thread -> cpu$cpu_cpu"
  [ -n "${GPU_TID:-}" ] && taskset -pc "$vid_cpu" "$GPU_TID" >/dev/null 2>&1 &&
    echo "  pinned video thread -> cpu$vid_cpu"
fi

# warmup past state loading / shader creation
sleep "${WARMUP:-8}"

read_thread() { # read_thread <tid> -> utime+stime in clock ticks
  awk '{print $14 + $15}' "/proc/$PID/task/$1/stat" 2>/dev/null
}
# schedstat: "runtime_ns wait_ns timeslices". runtime is time ON a CPU, wait is
# time RUNNABLE but queued behind other tasks. A thread that is missing frames
# while its runtime is high and its wait is high is being preempted; one whose
# runtime+wait is well under wall clock is blocked (in dual core mode that is
# usually FIFO backpressure from the GPU thread, which is a different fix).
read_schedstat() { # read_schedstat <tid>
  cat "/proc/$PID/task/$1/schedstat" 2>/dev/null | awk '{print $1, $2}'
}
read_proc_field() { # read_proc_field <stat field number>
  awk -v f="$1" '{print $f}' "/proc/$PID/stat" 2>/dev/null
}

HZ=$(getconf CLK_TCK)
start=$(date +%s%N)
ss0=$(read_schedstat "$CPU_TID")
cpu0=$(read_thread "$CPU_TID")
gpu0=$([ -n "${GPU_TID:-}" ] && read_thread "$GPU_TID" || echo 0)
minflt0=$(read_proc_field 10)
majflt0=$(read_proc_field 12)

speeds=""
[ "${TRACE:-0}" = "1" ] && printf "   t  speed  on-cpu  blocked  gpu\n"
prev_ns=$start
prev_run=$(echo "$ss0" | awk '{print $1}')
prev_wait=$(echo "$ss0" | awk '{print $2}')
t=0
for _ in $(seq 1 "$DUR"); do
  sleep 1
  t=$((t + 1))
  s=$(sed -n 's/^speed=//p' "$AUTO/status.txt" 2>/dev/null | head -1)
  [ -n "$s" ] && speeds="$speeds $s"
  if [ "${TRACE:-0}" = "1" ]; then
    now_ns=$(date +%s%N)
    ss=$(read_schedstat "$CPU_TID")
    run=$(echo "$ss" | awk '{print $1}')
    wait=$(echo "$ss" | awk '{print $2}')
    # shellcheck disable=SC2086
    awk -v t="$t" -v s="${s:-?}" -v pn="$prev_ns" -v nn="$now_ns" \
        -v pr="$prev_run" -v r="$run" -v pw="$prev_wait" -v w="$wait" -v hz="$HZ" \
        -v c0="$cpu0" -v c1="$(read_thread "$CPU_TID")" -v g="$GPU_TID" -v pid="$PID" '
      BEGIN {
        el = (nn - pn) / 1e9
        on = (r - pr) / 1e9
        bl = 1 - (r - pr + w - pw) / 1e9 / el
        printf "%4d  %.3f   %5.1f%%   %5.1f%%\n", t, s + 0, 100 * on / el, 100 * bl
      }'
    prev_ns=$now_ns
    prev_run=$run
    prev_wait=$wait
  fi
done

end=$(date +%s%N)
ss1=$(read_schedstat "$CPU_TID")
cpu1=$(read_thread "$CPU_TID")
gpu1=$([ -n "${GPU_TID:-}" ] && read_thread "$GPU_TID" || echo 0)
minflt1=$(read_proc_field 10)
majflt1=$(read_proc_field 12)

elapsed=$(awk -v a="$start" -v b="$end" 'BEGIN{printf "%.3f", (b-a)/1e9}')
rss=$(awk '/^VmRSS:/{print $2}' "/proc/$PID/status" 2>/dev/null)
vsw=$(awk '/^VmSwap:/{print $2}' "/proc/$PID/status" 2>/dev/null)

# shellcheck disable=SC2086
awk -v label="$LABEL" -v el="$elapsed" -v hz="$HZ" \
    -v c0="$cpu0" -v c1="$cpu1" -v g0="$gpu0" -v g1="$gpu1" \
    -v mf0="$minflt0" -v mf1="$minflt1" -v mj0="$majflt0" -v mj1="$majflt1" \
    -v rss="${rss:-0}" -v vsw="${vsw:-0}" -v speeds="$speeds" \
    -v ss0="$ss0" -v ss1="$ss1" '
  function mean(a,   i, n, s) { n = split(a, x, " "); s = 0; for (i = 1; i <= n; i++) s += x[i]; return n ? s / n : 0 }
  function minof(a,   i, n, m) { n = split(a, x, " "); m = 1e9; for (i = 1; i <= n; i++) if (x[i] + 0 < m) m = x[i] + 0; return n ? m : 0 }
  BEGIN {
    cpu_busy = (c1 - c0) / hz / el
    gpu_busy = (g1 - g0) / hz / el
    n = split(speeds, x, " ")
    below = 0
    for (i = 1; i <= n; i++) if (x[i] + 0 < 0.98) below++
    printf "%s  speed mean=%.4f min=%.4f  (%.0f%% of seconds < 0.98)\n",
           label, mean(speeds), minof(speeds), n ? 100 * below / n : 0
    printf "  CPU thread busy: %.1f%% of one core   Video thread: %.1f%%\n",
           100 * cpu_busy, 100 * gpu_busy
    printf "  page faults: %.0f minor/s, %.0f major/s   RSS %d MB  swap %d MB\n",
           (mf1 - mf0) / el, (mj1 - mj0) / el, rss / 1024, vsw / 1024
    split(ss0, a, " "); split(ss1, b, " ")
    run_s = (b[1] - a[1]) / 1e9
    wait_s = (b[2] - a[2]) / 1e9
    printf "  CPU thread: on-cpu %.1f%%  runqueue-wait %.1f%%  blocked %.1f%%\n",
           100 * run_s / el, 100 * wait_s / el, 100 * (1 - (run_s + wait_s) / el)
    if (run_s / el > 0.95)
      print  "  verdict: SATURATED - owns its core and still misses; cut work (codegen/host glue)"
    else if (wait_s / el > 0.05)
      printf "  verdict: PREEMPTED - %.0f%% of the time it was runnable but queued; raise its priority\n",
             100 * wait_s / el
    else
      printf "  verdict: BLOCKED - %.0f%% of the time it was not runnable at all; it is waiting on\n" \
             "            the GPU thread / FIFO backpressure, so the GPU side is the bottleneck\n",
             100 * (1 - (run_s + wait_s) / el)
    if (rss == 0) printf "  WARNING: no /proc readings (process gone?)\n"
  }'
echo "  log: $LOG"

"$DIR/tools/killgame.sh" >/dev/null
