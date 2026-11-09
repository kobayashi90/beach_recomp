#!/bin/bash
# prunebuild.sh [--build] [--variants NAME]
#
# Regenerate the module's chunk sources from the pristine copy and re-apply the
# dispatch pruning with the canonical entry set. This exists because pruning was
# previously a hand-typed command: nothing in the build pipeline ran
# prune_dispatch.py, so any regeneration (DolRecomp re-run, a new module hash)
# silently produced an UNPRUNED tree and the next measurement was comparing
# something else entirely.
#
# Two invariants this script enforces:
#
#   * always prune FROM build/chunks_pristine, never from the live tree. Pruning
#     is a one-way text rewrite (cases are deleted), so re-pruning an already
#     pruned tree cannot restore anything that was cut. Keeping the original set
#     of files is the only way to make the step repeatable.
#   * always pass --default-fallback. The entry set is runtime evidence: `blr`
#     returns through a guest stack slot and `bctr` through a guest table, so the
#     addresses the chassis dispatches to are not statically knowable. Without
#     the fallback a missing case is `default: return;` with pc unchanged, which
#     spins until the timeslice expires -- that is the 16 fps crater of
#     2026-11-07, not a hang you can see coming.
#
# --build additionally compiles into module-build-plain (the no-PGO build), which
# is the control variant: -fprofile-use re-inflates the pruned code by ~3.5x, so
# a PGO build of pruned sources is not a valid measurement of pruning.
set -u

DIR=/home/lain/opencode/beach_recomp
# Which region's module to prune. Each region keeps its own pristine copy,
# backup and output name: the chunk sources differ per disc, and pruning is a
# one-way rewrite, so sharing a pristine directory between regions would
# silently prune the wrong tree.
REGION=${REGION:-GBSP8P}
MODULE_NAME="g${REGION}_recomp.so"
if [ -d "$DIR/build/chunks_pristine-$REGION" ]; then
  PRISTINE="$DIR/build/chunks_pristine-$REGION"
else
  # PAL's pristine copy predates the per-region naming.
  PRISTINE="$DIR/build/chunks_pristine"
fi
ENTRY="$DIR/build/entries/union.txt"
DO_BUILD=0
VARIANT=""

while [ $# -gt 0 ]; do
  case $1 in
    --build) DO_BUILD=1 ;;
    --variants) VARIANT=${2:?--variants needs a name}; shift ;;
    *) echo "usage: prunebuild.sh [--build] [--variants NAME]" >&2; exit 2 ;;
  esac
  shift
done

[ -d "$PRISTINE" ] || { echo "no pristine chunk set at $PRISTINE" >&2; exit 1; }
[ -s "$ENTRY" ] || { echo "no entry set at $ENTRY (run tools/widen.sh)" >&2; exit 1; }

M=$(ls -d "$DIR"/build/modules/"$REGION"/*/ 2>/dev/null | head -1)
[ -n "$M" ] || { echo "no module build directory for $REGION" >&2; exit 1; }
# `ls -d .../ | head` yields a trailing slash; strip it so paths read normally.
M=${M%/}
GEN="$M/dolrecomp-output/generated/chunks"
[ -d "$GEN" ] || { echo "no generated chunks at $GEN" >&2; exit 1; }

# Measuring or playing: never rewrite sources under a live process. Reading a
# .so is fine, replacing one is not, and a rebuild would starve the game anyway.
if pgrep -x moderngekko-run >/dev/null; then
  echo "prunebuild: an emulator is running; not touching sources" >&2
  exit 1
fi

echo "pristine -> generated ($(ls "$PRISTINE"/*.c | wc -l) files)"
cp "$PRISTINE"/*.c "$GEN"/

echo "pruning with entry set $ENTRY ($(wc -l <"$ENTRY") addresses)"
python3 "$DIR/tools/prune_dispatch.py" "$GEN" \
  --entry-extra "$ENTRY" \
  --default-fallback \
  --backup "$DIR/build/chunks_pruned_backup-$REGION" || exit 1

# The backup is a convenience for diffing, not the restore source; pristine is.
echo "pruned tree ready at $GEN"

if [ "$DO_BUILD" = 1 ]; then
  BD="$M/module-build-plain"
  [ -d "$BD" ] || { echo "no $BD (configure it first)" >&2; exit 1; }
  echo "building (ninja -j6) -- ~20 min"
  ( cd "$BD" && ninja -j6 ) || exit 1
  if [ -n "$VARIANT" ]; then
    cp "$BD/$MODULE_NAME" "$DIR/build/variants/g${REGION}_${VARIANT}.so"
    echo "saved build/variants/g${REGION}_${VARIANT}.so"
  fi
fi
