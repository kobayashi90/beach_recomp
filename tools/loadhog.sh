#!/bin/bash
# loadhog.sh N [SECONDS]
#
# Holds N runnable CPU hogs for SECONDS (0 = until killed), as a *reproducible*
# stand-in for ambient desktop load. round-to-round comparisons of cpf.sh were
# uninterpretable because "ambient load" was whatever happened to be running
# (ShadowPCDisplay, electron, kwin, wineserver), moving loadavg between 0.8 and
# 4.2 with no record of it. A synthetic hog is the same kind of contention but
# you can state its value.
#
# The hogs are plain `yes > /dev/null` loops at nice 0: they compete for CFS
# time exactly like an ordinary foreground process does, and they stop the
# moment this script is killed (the whole process group is torn down).
#
# Usage:
#   tools/loadhog.sh 2 60 &        # two hogs for a minute
#   tools/loadhog.sh 2 &           # until killed
set -u
N=${1:-1}
DUR=${2:-0}
[ "$N" -ge 1 ] || { echo "usage: loadhog.sh N [SECONDS]" >&2; exit 2; }

pids=()
for _ in $(seq 1 "$N"); do
  yes >/dev/null &
  pids+=("$!")
done

cleanup() { kill "${pids[@]}" 2>/dev/null; wait 2>/dev/null; }
trap cleanup EXIT INT TERM

if [ "$DUR" -gt 0 ]; then
  sleep "$DUR"
else
  wait
fi
