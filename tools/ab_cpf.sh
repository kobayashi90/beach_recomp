#!/bin/bash
export MG_HARNESS=1  # marks this as a measurement instance; killgame.sh refuses to touch an unmarked one
# ab_cpf.sh <label_a> <so_a> <label_b> <so_b> [rounds] [seconds]
#
# Interleaved A/B on cycles-per-guest-frame, because the box's ambient load
# (ShadowPCDisplay, electron, kwin_wayland, wineserver) moves between 0.8 and 4.2
# loadavg and a single run per variant just measures which one got the quieter
# minute. Each round runs A then B, so drift hits both sides equally, and the
# per-round deltas show whether the result is stable.
#
# Runs are spaced so the module is never rewritten while it is dlopen()ed.
set -u

DIR=/home/lain/opencode/beach_recomp
LA=${1:?usage: ab_cpf.sh label_a so_a label_b so_b [rounds] [seconds]}
SA=${2:?}
LB=${3:?}
SB=${4:?}
ROUNDS=${5:-2}
DUR=${6:-110}

for so in "$SA" "$SB"; do
  [ -f "$so" ] || { echo "missing module: $so" >&2; exit 1; }
done

OUT=$(mktemp -d /tmp/mgab-XXXXXX)
extract() {  # pull the mean/worst Mcycles-per-frame out of a cpf.sh run
  awk '/Mcycles\/frame/ {printf "%s %s %s", $5, $9, $13} /seconds over budget|all clear/ {printf " over=%s\n", $4}' "$1"
}

for r in $(seq 1 "$ROUNDS"); do
  for side in A B; do
    if [ "$side" = A ]; then lbl=$LA; so=$SA; else lbl=$LB; so=$SB; fi
    f="$OUT/$r$side.txt"
    MODULE="$so" "$DIR/tools/cpf.sh" "$lbl" "$DUR" 2>&1 | tee "$f" >/dev/null
    printf 'round %d %s %-8s %s\n' "$r" "$side" "$lbl" "$(grep -A3 'Mcycles/frame' "$f" | tr '\n' ' ' | sed 's/  */ /g')"
  done
done

echo
echo "=== per-variant spread across rounds ==="
for side in A B; do
  if [ "$side" = A ]; then lbl=$LA; else lbl=$LB; fi
  for r in $(seq 1 "$ROUNDS"); do
    printf '  %-8s round %d  %s\n' "$lbl" "$r" "$(grep 'Mcycles/frame' "$OUT/$r$side.txt" | sed 's/^ *//')"
  done
done
echo "logs kept in $OUT"
