#!/bin/bash
# widen.sh [FILE...]
#
# Rebuild the canonical entry set that prune_dispatch.py unions in, and report
# what changed.
#
# The entry set is *runtime evidence*, not build output: a pruned switch is only
# correct for the addresses actually recorded. Keep it under build/entries/ so a
# regeneration can be re-pruned from the same evidence, and always keep the
# `--default-fallback` handler so an unrecorded address is merely slow rather
# than a silent spin.
#
# With no FILE arguments it unions everything already collected in
# build/entries/sources/ plus the mandatory seed list.
#
# Usage:
#   widen.sh logs/cov-gameplay-120000.entries.sorted logs/cov-gameplay-120000.entries.miss
set -u

DIR=/home/lain/opencode/beach_recomp
STORE="$DIR/build/entries"
SRC="$STORE/sources"
UNION="$STORE/union.txt"
mkdir -p "$SRC"

# Addresses found the hard way: a pruned build stalled on these because no
# capture run had dispatched to them yet. They are kept unconditionally so the
# next iteration starts from what is already known.
SEED="$STORE/seed.txt"
if [ ! -f "$SEED" ]; then
  printf '800715A8\n8004B168\n' >"$SEED"
fi

for f in "$@"; do
  [ -f "$f" ] || { echo "missing: $f" >&2; continue; }
  cp "$f" "$SRC/$(basename "$f")"
done

# Accept both blobs of addresses (the STATICRECOMP_ENTRY_LOG dump) and anything
# that merely contains them; keep only well-formed 8-digit hex, upper case.
cat "$SEED" "$SRC"/* 2>/dev/null \
  | grep -oE '(^|[^0-9A-Fa-f])[0-9A-Fa-f]{8}([^0-9A-Fa-f]|$)' \
  | grep -oE '[0-9A-Fa-f]{8}' \
  | tr 'a-f' 'A-F' \
  | sort -u >"$UNION.tmp"
mv "$UNION.tmp" "$UNION"

echo "entry set: $(wc -l <"$UNION") addresses -> $UNION"
echo "sources  : $(ls "$SRC" | wc -l) file(s) in $SRC"
