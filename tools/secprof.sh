#!/bin/bash
export MG_HARNESS=1  # marks this as a measurement instance; killgame.sh refuses to touch an unmarked one
# secprof.sh LABEL [SECONDS]
#
# Per-second profile of the CPU thread, correlated with the emulator's own speed
# readout. The aggregate profile ("where the time goes") blends fast and slow
# content, so it cannot answer "why was second 9 slow": this samples one second
# at a time and prints the speed next to the hot symbols for that same second.
#
# Use it on content whose dips reproduce (a savestate run does: the same second
# of the same state is slow to within ~2 %), then compare a slow column against a
# fast one to see which chunks the dip is actually made of.
set -u

DIR=/home/lain/opencode/beach_recomp
LABEL=${1:?usage: secprof.sh LABEL [seconds] [extra args...]}
DUR=${2:-20}
shift 2 2>/dev/null || shift 1

SO=${MODULE:-$(ls -d "$DIR"/build/modules/GBSP8P/*/gGBSP8P_recomp.so 2>/dev/null | head -1)}
[ -z "$SO" ] && { echo "no module .so"; exit 1; }

"$DIR/tools/killgame.sh" >/dev/null || { echo "cannot free the emulator slot"; exit 1; }
sleep 1

AUTO=$(mktemp -d /tmp/mgsecprof-XXXXXX)
STAMP=$(date +%H%M%S)
LOG="$DIR/logs/secprof-${LABEL}-${STAMP}.log"
OUT="$DIR/logs/secprof-${LABEL}-${STAMP}"
MAPS="$OUT.maps"
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
cp "/proc/$PID/maps" "$MAPS"
python3 "$DIR/tools/profsnap.py" "$MAPS" "$DIR/logs/profile-blobs" \
  "$DIR/" "/home/lain/opencode/beach_recomp/" >/dev/null 2>&1

SAMPLES=""
for i in $(seq 1 "$DUR"); do
  f="$OUT.$i.samples"
  "$DIR/tools/profsample" "$PID" 1 "${HZ:-997}" >"$f"
  echo "$i $(sed -n 's/^speed=//p' "$AUTO/status.txt" | head -1)" >>"$OUT.speed"
  SAMPLES="$SAMPLES $f"
done

"$DIR/tools/killgame.sh" >/dev/null

python3 - "$CPU_TID" "$MAPS" "$OUT.speed" $SAMPLES <<'PY'
import bisect, os, sys
sys.path.insert(0, "/home/lain/opencode/beach_recomp/tools")
import profsym
from collections import Counter

cpu_tid, maps_path, speed_path = sys.argv[1], sys.argv[2], sys.argv[3]
files = sys.argv[4:]

maps = profsym.parse_maps(maps_path)
starts = [m[0] for m in maps]
symcache = {}

def label_for(ip):
    i = bisect.bisect_right(starts, ip) - 1
    if i < 0 or ip >= maps[i][1]:
        return None
    start, _end, moff, name = maps[i]
    if not name.startswith("/") or not os.path.exists(name):
        return f"{name}+0x{ip - start + moff:x}" if name else None
    if name not in symcache:
        syms = profsym.elf_symbols(name)
        symcache[name] = (syms, [s[0] for s in syms])
    syms, addrs = symcache[name]
    sym = profsym.lookup(syms, addrs, ip - start + moff) if syms else None
    base = os.path.basename(name)
    return f"{sym} [{base}]" if sym else f"+0x{ip - start + moff:x} [{base}]"

speeds = {}
for line in open(speed_path):
    parts = line.split()
    if len(parts) == 2:
        speeds[parts[0]] = parts[1]

for n, path in enumerate(files, 1):
    counts = Counter()
    total = 0
    for line in open(path):
        parts = line.split()
        if len(parts) != 3 or parts[1] != cpu_tid:
            continue
        count = int(parts[0])
        total += count
        lab = label_for(int(parts[2], 16))
        if lab:
            counts[lab] += count
    sp = speeds.get(str(n), "?")
    mark = "  <-- slow" if sp != "?" and float(sp) < 0.95 else ""
    top = ", ".join(f"{name.split(' [')[0]} {100*c/max(total,1):.0f}%"
                    for name, c in counts.most_common(4))
    print(f"t={n:2d} speed={sp:>8}  cpu-samples={total:4d}  {top}{mark}")
PY

echo "  log: $LOG"
