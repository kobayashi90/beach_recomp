#!/bin/bash
export MG_HARNESS=1  # marks this as a measurement instance; killgame.sh refuses to touch an unmarked one
# speed.sh LABEL [seconds] [extra launcher args...]
#
# Launches ModernGekko with --automation-dir and samples the emulator's own
# speed/vps numbers, then stops it. speed is the number that matters: 1.0 means
# emulated time advances at wall-clock rate, so the 50 Hz game reports fps=50.
#
# Hard rule: exactly ONE instance may run. Leaving a previous instance alive
# splits the present path and reports 0.61 (two) or 0.40 (three), which looks
# like a performance wall but is pure harness garbage. The script therefore
# waits for a real teardown before starting, re-checks during the run, and
# refuses to print numbers if a stray appeared.
set -u

DIR=/home/lain/opencode/beach_recomp
LABEL=${1:?usage: speed.sh LABEL [seconds] [extra args...]}
DUR=${2:-30}
shift 2 2>/dev/null || shift 1

# The disc and the module are a pair, same as in menu-ui.sh: pointing the
# NTSC-U module at extracted/beach would load the wrong game root and report
# nonsense. REGION picks the pair (default PAL); GAME/MODULE override it for
# a region the table does not know.
REGION=${REGION:-GBSP8P}
if [ -z "${GAME:-}" ] || [ -z "${MODULE:-}" ]; then
  case "$REGION" in
    GBSP8P) def_game=$DIR/extracted/beach ;;
    GBSE8P) def_game=$DIR/extracted/beach-us ;;
    *)      def_game=${GAME:?set GAME and MODULE for unknown region $REGION} ;;
  esac
  def_so=$(ls -d "$DIR"/build/modules/"$REGION"/*/g"${REGION}"_recomp.so 2>/dev/null | head -1)
fi
GAME_DIR=${GAME:-${def_game:?no module .so for region $REGION}}
SO=${MODULE:-${def_so:-}}
[ -z "$SO" ] && { echo "no module .so"; exit 1; }
[ -d "$GAME_DIR" ] || { echo "no game dir: $GAME_DIR"; exit 1; }

"$DIR/tools/killgame.sh" >/dev/null || { echo "cannot free the emulator slot"; exit 1; }
sleep 1

AUTO=$(mktemp -d /tmp/mgspeed-XXXXXX)
LOG="$DIR/logs/speed-${LABEL}-$(date +%H%M%S).log"
cd "$DIR" || exit 1

# PIN="2,3" confines every thread of the run to those logical cpus. This box is
# a 4-core i3 with SMT and the desktop keeps a core busy, so an unpinned run
# migrates ~30x/s (CPU thread) and ~110x/s (video thread) and occasionally lands
# both hot threads on one physical core -- which reads as "the emulator needs
# 1.3x the CPU". Leave it unset for the default (kernel-chosen) placement.
PIN_CMD=()
[ -n "${PIN:-}" ] && PIN_CMD=(taskset -c "$PIN")

# shellcheck disable=SC2086
setsid nohup "${PIN_CMD[@]}" ./lib/ModernGekko/build/moderngekko-run \
  --game "$GAME_DIR" --module "$SO" --wayland --automation-dir "$AUTO" \
  "$@" >"$LOG" 2>&1 </dev/null &

for _ in $(seq 1 25); do
  [ -f "$AUTO/status.txt" ] && break
  sleep 1
done
if [ ! -f "$AUTO/status.txt" ]; then
  echo "$LABEL: never booted (see $LOG)"
  "$DIR/tools/killgame.sh" >/dev/null
  exit 1
fi

# NAV=1 walks the opening screens into a match before sampling, and INPUT=1
# keeps feeding the pad while sampling, so the measured frames are gameplay
# rather than attract mode. This matters because attract is a much cheaper
# workload than a match: both regions report 1.000 there, so attract alone
# cannot answer "is NTSC-U as fast as PAL where it matters". The Start/A
# hammer is the same one coverage.sh uses -- the opening screens all advance
# on Start or A, so no per-screen state machine is needed. Input during the
# sample is a fixed cycle rather than $RANDOM so both regions see the same
# sequence.
seq=0
send() { # send <name> <field>=<value>...
  local name=$1
  shift
  seq=$((seq + 1))
  printf '%s\n' "$@" >"$AUTO/commands/$(printf '%03d' "$seq")-$name.txt"
}

if [ "${NAV:-0}" = "1" ]; then
  sleep 10
  for _ in 1 2 3 4 5 6; do
    send "nav-start" "command=pad_frames" "port=0" "frames=8" "start=1"
    sleep 0.6
    send "nav-a" "command=pad_frames" "port=0" "frames=8" "a=1"
    sleep 0.6
  done
fi

SAMPLES="$AUTO/samples.txt"
: >"$SAMPLES"
step=0
tick=0

# PERF=1 additionally samples cycles/instructions/branches via tools/perfcount,
# which is what tells apart two modules that both reach speed 1.000.
PERFLOG="$DIR/logs/perf-${LABEL}-$(date +%H%M%S).txt"
if [ "${PERF:-0}" = "1" ]; then
  PID=$(pgrep -x moderngekko-run | head -1)
  ( sleep 5; "$DIR"/tools/perfcount "$PID" "$DUR" >"$PERFLOG" 2>&1 ) &
  PERFPID=$!
fi
STRAY=0
for _ in $(seq 1 "$DUR"); do
  sleep 1
  tick=$((tick + 1))
  # A screenshot every SHOTSTEP seconds, so a run shows which screen each part
  # of its average came from. Sent without sleeping: the emulator writes it
  # asynchronously and SHOTSTEP seconds is far longer than the write takes.
  if [ -n "${SHOTDIR:-}" ] && [ "${SHOTSTEP:-0}" != "0" ] &&
     [ $((tick % SHOTSTEP)) -eq 0 ]; then
    mkdir -p "$SHOTDIR"
    send "shot$tick" "command=screenshot" \
      "path=$SHOTDIR/$LABEL-$(printf '%03d' "$tick").png"
  fi
  if [ "${INPUT:-0}" = "1" ]; then
    step=$((step + 1))
    case $((step % 4)) in
      0) send "in-move-a" "command=pad_frames" "port=0" "frames=20" \
            "main_x=0.60" "main_y=-0.20" "c_x=0.00" "c_y=0.00" ;;
      1) send "in-a" "command=pad_frames" "port=0" "frames=6" "a=1" ;;
      2) send "in-move-b" "command=pad_frames" "port=0" "frames=20" \
            "main_x=-0.60" "main_y=0.20" "c_x=0.00" "c_y=0.00" ;;
      3) send "in-b" "command=pad_frames" "port=0" "frames=6" "b=1" ;;
    esac
  fi
  # pgrep -c prints "0" AND exits 1 when nothing matches, so `|| echo 0` used to
  # produce "0<newline>0" and made `[ ... -eq 1 ]` fail with a locale error on
  # every tick -- which then reported a bogus STRAY INSTANCE. Read the count
  # without the fallback.
  INST=$(pgrep -xc moderngekko-run 2>/dev/null) || true
  [ "${INST:-0}" -eq 1 ] || STRAY=1
  [ -f "$AUTO/status.txt" ] || continue
  s=$(sed -n 's/^speed=//p' "$AUTO/status.txt" | head -1)
  f=$(sed -n 's/^fps=//p' "$AUTO/status.txt" | head -1)
  v=$(sed -n 's/^vps=//p' "$AUTO/status.txt" | head -1)
  [ -n "$s" ] && echo "$s $f $v" >>"$SAMPLES"
done

# TRACE=1 keeps the per-second series. A single average hides which screen the
# number came from: a run parked on a menu and a run in a match both average
# out, and only the trace (together with the screenshots) separates them.
if [ "${TRACE:-0}" = "1" ] && [ -s "$SAMPLES" ]; then
  cp "$SAMPLES" "$DIR/logs/speed-${LABEL}-samples.txt"
fi

# SHOTDIR: ask the emulator for a screenshot at the end of the sample, so a run
# can prove WHAT it measured. speed alone says nothing about which screen was
# up, and "1.000 in attract" and "1.000 in a match" are different claims.
if [ -n "${SHOTDIR:-}" ]; then
  mkdir -p "$SHOTDIR"
  send "shot" "command=screenshot" "path=$SHOTDIR/$LABEL.png"
  sleep 2
fi

# SAVESTATE=<file>: write a savestate at the end of the sample. Savestates are
# region-specific, so each region needs its own gameplay state -- PAL's cannot
# be loaded by the NTSC-U build. Saving at the end of a NAV+INPUT run puts the
# state in the middle of a match, which is the workload PGO has to be trained
# on (attract mode is a different, much cheaper code path).
if [ -n "${SAVESTATE:-}" ]; then
  send "save" "command=save_state" "path=$SAVESTATE"
  sleep 3
  [ -f "$SAVESTATE" ] && echo "  state: $SAVESTATE ($(stat -c%s "$SAVESTATE") bytes)" \
                      || echo "  state: FAILED to write $SAVESTATE"
fi

[ "${PERF:-0}" = "1" ] && wait "${PERFPID:-}" 2>/dev/null
"$DIR/tools/killgame.sh" >/dev/null

# Drop the first third (boot, shader warmup) before averaging.
awk -v label="$LABEL" -v stray="$STRAY" '
  { n++; sp[n]=$1; fp[n]=$2; vp[n]=$3 }
  END {
    start = int(n/3) + 1;
    if (start < 1) start = 1;
    for (i = start; i <= n; i++) { ss += sp[i]; sf += fp[i]; sv += vp[i]; c++ }
    if (!c) { printf "%-16s no samples\n", label; exit }
    printf "%-16s speed=%.3f fps=%6.2f vps=%6.2f  (n=%d)%s\n",
           label, ss/c, sf/c, sv/c, c, (stray ? "  !! STRAY INSTANCE SEEN" : "")
  }' "$SAMPLES"
if [ "${PERF:-0}" = "1" ] && [ -s "$PERFLOG" ]; then
  grep -E "^(threads|seconds|cycles|instructions|IPC|branches)" "$PERFLOG" | sed "s/^/  /"
  echo "  perf: $PERFLOG"
fi
echo "  log: $LOG"
rm -rf "$AUTO"
