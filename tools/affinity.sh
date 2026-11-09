#!/bin/bash
export MG_HARNESS=1  # marks this as a measurement instance; killgame.sh refuses to touch an unmarked one
# affinity.sh LABEL [SECONDS]
#
# Where do the two threads that decide the frame rate actually run, and do they
# end up on the SAME physical core?
#
# This box is a 4-core i3-10100 with hyper-threading, so cpus (0,4), (1,5),
# (2,6), (3,7) are siblings of one physical core. Two busy threads that share a
# sibling pair each get roughly half of the core's real throughput, which looks
# exactly like "the emulator suddenly needs 1.3x more CPU" -- and it is fixed by
# pinning, not by optimisation.
#
# Samples /proc/<tid>/stat's "last cpu" field for the CPU thread and the video
# thread every 2 ms and reports the pair distribution plus how often the pair is
# a hyper-thread sibling pair. Also reports migrations, because a thread that
# keeps bouncing between cores pays for cold L1/L2 every hop.
set -u

DIR=/home/lain/opencode/beach_recomp
LABEL=${1:?usage: affinity.sh LABEL [seconds] [extra args...]}
DUR=${2:-10}
shift 2 2>/dev/null || shift 1

# REGION picks the disc/module pair, same convention as speed.sh, because the
# threads' placement depends on what the guest is doing and a PAL module cannot
# be pointed at the NTSC-J game root.
REGION=${REGION:-GBSP8P}
case "$REGION" in
  GBSP8P) def_game=$DIR/extracted/beach ;;
  GBSE8P) def_game=$DIR/extracted/beach-us ;;
  GBSJ8P) def_game=$DIR/extracted/beach-jp ;;
  *)      def_game=${GAME:?set GAME for unknown region $REGION} ;;
esac
GAME_DIR=${GAME:-$def_game}
SO=${MODULE:-$(ls -d "$DIR"/build/modules/"$REGION"/*/g"${REGION}"_recomp.so 2>/dev/null | head -1)}
[ -z "$SO" ] && { echo "no module .so"; exit 1; }
[ -d "$GAME_DIR" ] || { echo "no game dir: $GAME_DIR"; exit 1; }

"$DIR/tools/killgame.sh" >/dev/null || { echo "cannot free the emulator slot"; exit 1; }
sleep 1

AUTO=$(mktemp -d /tmp/mgaff-XXXXXX)
LOG="$DIR/logs/affinity-${LABEL}-$(date +%H%M%S).log"
cd "$DIR" || exit 1
# shellcheck disable=SC2086
setsid nohup ./lib/ModernGekko/build/moderngekko-run \
  --game "$GAME_DIR" --module "$SO" --wayland --automation-dir "$AUTO" \
  "$@" >"$LOG" 2>&1 </dev/null &

for _ in $(seq 1 40); do
  [ -f "$AUTO/status.txt" ] && break
  sleep 1
done
[ -f "$AUTO/status.txt" ] || { echo "$LABEL: never booted (see $LOG)"; "$DIR/tools/killgame.sh" >/dev/null; exit 1; }

PID=$(pgrep -x moderngekko-run | head -1)
tid_of() {
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
GPU_TID=$(tid_of "Video thread") || { echo "$LABEL: no video thread"; "$DIR/tools/killgame.sh" >/dev/null; exit 1; }

sleep "${WARMUP:-8}"

python3 - "$PID" "$CPU_TID" "$GPU_TID" "$DUR" <<'PY'
import collections, sys, time

pid, cpu_tid, gpu_tid, dur = sys.argv[1], sys.argv[2], sys.argv[3], float(sys.argv[4])

# physical core of each logical cpu, from the topology
core_of = {}
for c in range(64):
    try:
        with open(f"/sys/devices/system/cpu/cpu{c}/topology/core_id") as f:
            core_of[c] = int(f.read().strip())
    except OSError:
        pass

def last_cpu(tid):
    try:
        with open(f"/proc/{pid}/task/{tid}/stat") as f:
            data = f.read().rsplit(")", 1)[1].split()
        return int(data[36])  # field 39 overall
    except (OSError, IndexError, ValueError):
        return -1

pairs = collections.Counter()
solo = collections.Counter()
mig_cpu = mig_gpu = 0
prev_c, prev_g = last_cpu(cpu_tid), last_cpu(gpu_tid)
samples = 0
end = time.monotonic() + dur
while time.monotonic() < end:
    c, g = last_cpu(cpu_tid), last_cpu(gpu_tid)
    samples += 1
    pairs[(c, g)] += 1
    solo[c] += 1
    if c != prev_c:
        mig_cpu += 1
    if g != prev_g:
        mig_gpu += 1
    prev_c, prev_g = c, g
    time.sleep(0.002)

sibling = sum(n for (c, g), n in pairs.items() if c >= 0 and g >= 0 and core_of.get(c) == core_of.get(g))
print(f"  samples: {samples}")
print(f"  CPU thread migrations: {mig_cpu}   video thread migrations: {mig_gpu}")
print(f"  time on a SHARED physical core: {100*sibling/max(samples,1):.1f}%")
print("  cpu thread placement:")
for c, n in solo.most_common(4):
    print(f"    cpu{c} (core {core_of.get(c,'?')})  {100*n/samples:5.1f}%")
print("  (cpu, video-cpu) pairs:")
for (c, g), n in pairs.most_common(6):
    shared = "SHARED CORE" if core_of.get(c) == core_of.get(g) else ""
    print(f"    cpu{c}+cpu{g}  {100*n/samples:5.1f}%  {shared}")
PY

echo "  log: $LOG"
"$DIR/tools/killgame.sh" >/dev/null
