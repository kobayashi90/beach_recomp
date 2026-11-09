#!/bin/bash
export MG_HARNESS=1  # marks this as a measurement instance; killgame.sh refuses to touch an unmarked one
# memdump.sh LABEL FRAME [extra launcher args...]
#
# Dump all of MEM1 (24 MiB) through the automation protocol once the guest
# reaches FRAME. Two runs that agree byte-for-byte at the same guest frame are
# executing the same code with the same data, so any rendering difference must
# live in the presentation path, not the emulated GPU command stream. This is
# how we check that a scheduling change (dual core, present mode) did not alter
# emulation when the screenshot API cannot be trusted.
set -u

DIR=/home/lain/opencode/beach_recomp
LABEL=${1:?usage: memdump.sh LABEL FRAME [args...]}
FRAME=${2:?}
shift 2

SO=${MODULE:-$(ls -d "$DIR"/build/modules/GBSP8P/*/gGBSP8P_recomp.so 2>/dev/null | head -1)}
[ -z "$SO" ] && { echo "no module .so"; exit 1; }

"$DIR/tools/killgame.sh" >/dev/null || { echo "cannot free the emulator slot"; exit 1; }
sleep 1

AUTO=$(mktemp -d /tmp/mgmem-XXXXXX)
mkdir -p "$AUTO/commands"
OUT="$DIR/logs/mem-${LABEL}.bin"
LOG="$DIR/logs/mem-${LABEL}-$(date +%H%M%S).log"
rm -f "$OUT".*
cd "$DIR" || exit 1

# shellcheck disable=SC2086
setsid nohup ./lib/ModernGekko/build/moderngekko-run \
  --game extracted/beach --module "$SO" --wayland --automation-dir "$AUTO" \
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

for _ in $(seq 1 4000); do
  f=$(sed -n 's/^frame_count=//p' "$AUTO/status.txt" | head -1)
  [ -n "$f" ] && [ "$f" -ge "$FRAME" ] && break
  sleep 0.02
done
REACHED=$(sed -n 's/^frame_count=//p' "$AUTO/status.txt" | head -1)

printf 'command=read_memory\naddress=0x80000000\nsize=0x1000000\npath=%s.0\n' "$OUT" \
  >"$AUTO/commands/010-read0.txt"
printf 'command=read_memory\naddress=0xC0000000\nsize=0x800000\npath=%s.1\n' "$OUT" \
  >"$AUTO/commands/011-read1.txt"
for _ in $(seq 1 300); do
  [ -s "$OUT.1" ] && break
  sleep 0.05
done
sleep 1
"$DIR/tools/killgame.sh" >/dev/null

if [ ! -s "$OUT.1" ]; then
  echo "$LABEL: memory dump failed (see $LOG)"
  exit 1
fi
cat "$OUT.0" "$OUT.1" >"$OUT"
cat "$OUT".0 "$OUT".1 | sha256sum | cut -d' ' -f1 | sed "s/^/$LABEL frame=$REACHED sha256=/"
rm -f "$OUT".0 "$OUT".1
