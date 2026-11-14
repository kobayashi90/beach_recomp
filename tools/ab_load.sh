#!/bin/bash
export MG_HARNESS=1  # marks this as a measurement instance; killgame.sh refuses to touch an unmarked one
# ab_load.sh <label_a> <so_a> <label_b> <so_b> [rounds] [seconds] [hogs]
#
# Interleaved A/B like ab_cpf.sh, but every run has the *same* synthetic
# background load (tools/loadhog.sh) held for its duration. That turns "is it
# stable?" into a statement about a stated number of competing runnable
# processes instead of a guess about whatever the desktop happened to be doing.
#
# Use it to answer two different questions:
#   * same module, different scheduling  -> is the dip ambient preemption?
#     (MG_NICE=... on one side, 0 on the other)
#   * same scheduling, different module  -> does the code change survive load?
#     (MODULE variants with the same hogs)
#
# The hogs are started before the emulator and killed after it, so the boot and
# shutdown portions are loaded too -- an unloaded boot would flatter both sides.
#
# Environment:
#   MG_NICE   niceness for the emulator (default 0; negative needs privileges)
#   WARMUP    seconds cpf.sh waits before sampling (default 8)
set -u

DIR=/home/lain/opencode/beach_recomp
LA=${1:?usage: ab_load.sh label_a so_a label_b so_b [rounds] [seconds] [hogs]}
SA=${2:?}
LB=${3:?}
SB=${4:?}
ROUNDS=${5:-2}
DUR=${6:-110}
HOGS=${7:-2}

for so in "$SA" "$SB"; do
  [ -f "$so" ] || { echo "missing module: $so" >&2; exit 1; }
done

OUT=$(mktemp -d /tmp/mgabload-XXXXXX)
extract() {  # mean/p90/worst Mcycles-per-frame + the ambient line from a run
  awk '/Mcycles\/frame/ {printf "%s %s %s", $5, $9, $13}
       /seconds over bud/ {printf " | %s over", $1}
       /ambient load/ {printf " | load %s/%s", $4, $7}' "$1"
}

run_one() {  # run_one <label> <so> <round>
  # the label must be in the filename: both A/B modules usually share a
  # basename (gGBSP8P_recomp.so), so round+basename alone would collide and
  # the second tee would truncate the first run's log.
  local lbl=$1 so=$2 rnd=$3 f="$OUT/${3}-${1}-${2##*/}.log"
  "$DIR/tools/loadhog.sh" "$HOGS" &
  local hog=$!
  sleep 1
  MG_NICE=${MG_NICE:-0} WARMUP=${WARMUP:-8} MODULE="$so" \
    "$DIR/tools/cpf.sh" "$lbl" "$DUR" 2>&1 | tee "$f" >/dev/null
  kill "$hog" 2>/dev/null
  wait "$hog" 2>/dev/null
}

echo "hogs=$HOGS  rounds=$ROUNDS  seconds=$DUR  nice=${MG_NICE:-0}"
for r in $(seq 1 "$ROUNDS"); do
  echo "--- round $r: $LA ---"
  run_one "$LA" "$SA" "$r"
  echo "--- round $r: $LB ---"
  run_one "$LB" "$SB" "$r"
done

echo
printf '%-16s %-28s %-28s\n' round "$LA" "$LB"
for r in $(seq 1 "$ROUNDS"); do
  printf '%-16s %-28s %-28s\n' "$r" \
    "$(extract "$OUT/$r-$LA-$(basename "$SA").log")" \
    "$(extract "$OUT/$r-$LB-$(basename "$SB").log")"
done
echo "logs: $OUT"
