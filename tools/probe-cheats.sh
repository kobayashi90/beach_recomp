#!/bin/bash
export MG_HARNESS=1
# probe-cheats.sh -- what can a "cheat" actually do in this build?
#
# The game is statically recompiled: guest code is native code generated at
# build time, so a cheat that depends on the *guest CPU* executing new
# instructions (Dolphin's Gecko/Action Replay code handler, which is copied into
# RAM at runtime) can only work if the guest is still being interpreted
# somewhere. This probe answers that instead of assuming either way:
#
#   1. enable cheats + the shipped 16:9 Gecko code
#   2. boot, give the handler a few seconds of frames to run
#   3. read back the addresses that code writes (0x80003500..)
#
# The handler writes 3C608017 C04348F8 4800B498... there. Zeros mean the handler
# never executed and only host-side memory patches can work.
set -u

DIR=/home/lain/opencode/beach_recomp
DATA=$HOME/.local/share/moderngekko
RUN=$DIR/lib/ModernGekko/build/moderngekko-run
SO=$(ls -1d "$DIR"/build/modules/GBSP8P/*/gGBSP8P_recomp.so 2>/dev/null | head -1)
WORK=/tmp/opencode/mg-probe-cheats
AUTO=$WORK/auto
LOG=$WORK/probe.log

rm -rf "$WORK"
mkdir -p "$AUTO/commands" "$WORK/backup"
cp "$DATA/Config/Dolphin.ini" "$WORK/backup/Dolphin.ini"
[[ -d $DATA/GameSettings ]] && cp -a "$DATA/GameSettings" "$WORK/backup/GameSettings"
cleanup() {
  "$DIR/tools/killgame.sh" >/dev/null 2>&1
  cp "$WORK/backup/Dolphin.ini" "$DATA/Config/Dolphin.ini"
  rm -rf "$DATA/GameSettings"
  [[ -d $WORK/backup/GameSettings ]] && cp -a "$WORK/backup/GameSettings" "$DATA/GameSettings"
}
trap cleanup EXIT

sed -i 's/^EnableCheats = .*/EnableCheats = True/' "$DATA/Config/Dolphin.ini"
grep -q '^EnableCheats' "$DATA/Config/Dolphin.ini" ||
  sed -i 's/^\[Core\]$/[Core]\nEnableCheats = True/' "$DATA/Config/Dolphin.ini"

mkdir -p "$DATA/GameSettings"
printf '[Gecko_Enabled]\n$16:9 Widescreen\n' >"$DATA/GameSettings/GBSP8P.ini"
echo "cheats enabled: $(grep '^EnableCheats' "$DATA/Config/Dolphin.ini")"
echo "local game ini:"; sed 's/^/    /' "$DATA/GameSettings/GBSP8P.ini"

"$DIR/tools/killgame.sh" >/dev/null 2>&1
sleep 1
MODERNGEKKO_MENU_DEBUG=1 \
  setsid nohup "$RUN" --game "$DIR"/extracted/beach --module "$SO" --wayland \
  --automation-dir "$AUTO" >"$LOG" 2>&1 </dev/null &
for _ in $(seq 1 30); do [[ -f $AUTO/status.txt ]] && break; sleep 1; done
[[ -f $AUTO/status.txt ]] || { echo "FAIL: never booted"; exit 1; }
sleep 12

seq=0
cmd() { local name=$1; shift; seq=$((seq + 1)); printf '%s\n' "$@" >"$AUTO/commands/$(printf '%03d' "$seq")-$name.txt"; }
field() { sed -n "s/^$1=//p" "$AUTO/status.txt" 2>/dev/null | head -1; }
hexdump_at() { # hexdump_at <address> <size> <file>
  cmd "read-$1" "command=read_memory" "address=$1" "size=$2" "path=$3"
  for _ in $(seq 1 100); do [[ -f $3 ]] && break; sleep 0.1; done
  if [[ -f $3 ]]; then
    printf '  %s: ' "$1"
    od -An -tx4 -v "$3" | tr -s ' ' | sed 's/^ //'
  else
    printf '  %s: (read failed: %s)\n' "$1" "$(field last_error)"
  fi
}

echo "=== guest memory the 16:9 code writes ==="
hexdump_at 0x80003500 16 "$WORK/at-3500.bin"
echo "=== the handler's own install area (0x80001800) ==="
hexdump_at 0x80001800 16 "$WORK/at-1800.bin"
echo "=== the patched branch site (0x8000E99C should be 4BFF4B64) ==="
hexdump_at 0x8000E99C 4 "$WORK/at-e99c.bin"

echo "=== dolpin log lines about cheats/gecko ==="
grep -n -i "gecko\|cheat\|codehandler\|action replay" "$LOG" | head -10
echo "=== status ==="
echo "  state=$(field state) fps=$(field fps) frames=$(field frame_count)"
