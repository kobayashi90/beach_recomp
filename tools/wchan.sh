#!/bin/bash
# wchan.sh LABEL [SECONDS]
#
# The CPU thread loses ~13 % of the wall clock to being *not runnable*, which
# starve.sh distinguishes from preemption. This says what it is waiting on:
# /proc/<tid>/wchan is the kernel function a sleeping task is parked in, so a
# histogram of it while the thread is off-CPU names the wait directly
# (futex_wait_queue = a lock/condvar in the emulator, a poll timeval = pacing,
# 0 = it was actually running).
#
# Also prints, per distinct wchan, the emulator-side user stack hint: the
# thread's own /proc/<tid>/stack needs root, so instead this reports whether the
# thread was in state S (interruptible) or D (uninterruptible I/O) and pairs the
# wait with the GPU thread's state at the same instant.
set -u

DIR=/home/lain/opencode/beach_recomp
LABEL=${1:?usage: wchan.sh LABEL [seconds] [extra args...]}
DUR=${2:-10}
shift 2 2>/dev/null || shift 1

SO=${MODULE:-$(ls -d "$DIR"/build/modules/GBSP8P/*/gGBSP8P_recomp.so 2>/dev/null | head -1)}
[ -z "$SO" ] && { echo "no module .so"; exit 1; }

"$DIR/tools/killgame.sh" >/dev/null || { echo "cannot free the emulator slot"; exit 1; }
sleep 1

AUTO=$(mktemp -d /tmp/mgwchan-XXXXXX)
LOG="$DIR/logs/wchan-${LABEL}-$(date +%H%M%S).log"
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
tid_of() { # tid_of <comm prefix>
  local i t c
  for ((i = 0; i < 100; i++)); do
    for t in /proc/"$PID"/task/*/; do
      c=$(cat "$t/comm" 2>/dev/null)
      case "$c" in "$1"*) echo "${t#/proc/$PID/task/}" | tr -d /; return 0 ;; esac
    done
    sleep 0.1
  done
  return 1
}
CPU_TID=$(tid_of "CPU thread") || { echo "$LABEL: no CPU thread"; "$DIR/tools/killgame.sh" >/dev/null; exit 1; }
GPU_TID=$(tid_of "Video thread") || true
AUD_TID=$(tid_of "Audio thread") || true

sleep "${WARMUP:-8}"

python3 - "$PID" "$CPU_TID" "${GPU_TID:-0}" "$DUR" <<'PY'
import collections, sys, time

pid, cpu_tid, gpu_tid, dur = sys.argv[1], sys.argv[2], sys.argv[3], float(sys.argv[4])

def read(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return ""

def state_of(tid):
    fields = read(f"/proc/{pid}/task/{tid}/stat").rsplit(")", 1)[-1].split()
    return fields[0] if fields else "?"

wchan = collections.Counter()
offs = collections.Counter()
total = 0
end = time.monotonic() + dur
while time.monotonic() < end:
    st = state_of(cpu_tid)
    total += 1
    if st != "R":
        w = read(f"/proc/{pid}/task/{cpu_tid}/wchan") or "0"
        wchan[w] += 1
        offs[(w, st, state_of(gpu_tid) if gpu_tid != "0" else "?")] += 1
    time.sleep(0.002)

print(f"  samples: {total}, off-CPU: {sum(wchan.values())} ({100*sum(wchan.values())/max(total,1):.1f}%)")
print("  where the CPU thread waits (wchan):")
for w, n in wchan.most_common(8):
    print(f"    {n:6d}  {100*n/max(sum(wchan.values()),1):5.1f}%  {w}")
print("  wait x cpu-state x gpu-state:")
for (w, st, gt), n in offs.most_common(6):
    print(f"    {n:6d}  cpu={st} gpu={gt}  {w}")
PY

echo "  log: $LOG"
"$DIR/tools/killgame.sh" >/dev/null
