#!/bin/bash
# play.sh [extra launcher args...]
#
# Launch ModernGekko with the display refresh rate matched to the game.
#
# Why: this is the PAL release of Beach Spikers, so the emulated VI runs at
# 50.00 Hz and produces a frame every 20.00 ms. A 60 Hz display has a vblank
# every 16.68 ms, and it cannot show 5 frames evenly in 6 vblanks, so the
# presentation engine holds one frame out of every five for a second vblank.
# That is 9.9 doubled frames per second -- a 10 Hz beat on top of the motion.
# The result is a rock-steady "50 fps" readout that still does not look smooth,
# which is exactly what "the opening is not 100% smooth" means here.
#
# The monitor has no 2560x1440 mode at 50 Hz (its EDID carries only 59.95, 120
# and 144 Hz at native), but its range limits are 48-144 Hz / 600 MHz dotclock,
# so a computed native mode at 50 Hz or 100 Hz is legal -- it just has to be
# created at kernel level with `video=HDMI-A-1:2560x1440@100` (see PERFORMANCE.md,
# "Matched refresh"). 100 Hz is the better choice: 100/50 = 2 exactly, so every
# frame is held two vblanks with no remainder.
#
# Nothing in userspace can add a mode (KWin has no custom-mode support), so this
# script can only fall back to the existing modes: the 50 Hz ones are 1920x1080
# and below. It reports "Vrr: incapable", so nothing else can fix the cadence.
# This script switches the output to the best available 50 Hz mode, runs the
# game, and puts the desktop back on exit (including on crash / Ctrl-C).
#
# The switch is OPT-IN: MG_MATCH_REFRESH=1. Default is off, so the desktop
# keeps its native mode (2560x1440@59.95) and the game runs at 50 Hz on a
# 60 Hz grid -- correct resolution, ~9.9 doubled frames per second.
set -u

DIR=/home/lain/opencode/beach_recomp
OUTPUT=${MG_OUTPUT:-HDMI-A-1}

SO=${MODULE:-$(ls -d "$DIR"/build/modules/GBSP8P/*/gGBSP8P_recomp.so 2>/dev/null | head -1)}
[ -z "$SO" ] && { echo "no module .so" >&2; exit 1; }

mode_list() {
  # Strip ANSI, then pull "id:WxH@R" entries out of the Modes: line.
  # NOTE the marker class is [*!]* and not [*!]?: the mode KWin is currently
  # showing AND that is the EDID-preferred one carries BOTH markers ("@59.95!*").
  # Allowing only one silently dropped exactly that entry, so the "current mode"
  # lookup fell through to the next mode in the list -- and the script then
  # "restored" the desktop to 1920x1440@75 instead of 2560x1440@60.
  kscreen-doctor -o 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' |
    grep -m1 'Modes:' | tr ' ' '\n' |
    grep -oE '^[0-9]+:[0-9]+x[0-9]+@[0-9.]+[*!]*$'
}

active_mode_id() {
  # The active mode is the one flagged with '*', NOT the first entry in the list.
  mode_list | grep '\*' | head -1 | grep -oE '^[0-9]+'
}

# Full "id:WxH@R" string of the current mode, e.g. 1:2560x1440@59.95
active_mode_desc() {
  mode_list | grep '\*' | head -1 | tr -d '*!'
}

pick_50hz_mode() {
  # Prefer the largest 50 Hz mode: 1080p50 > 720p50 > 576p50.
  local modes
  modes=$(mode_list)
  for want in '1920x1080@50' '1280x720@50' '720x576@50'; do
    local hit
    hit=$(printf '%s\n' "$modes" | grep -oE "[0-9]+:${want}[0-9.]*" | head -1 | tr -d '*!')
    [ -n "$hit" ] && { printf '%s' "${hit%%:*}"; return 0; }
  done
  return 1
}

restore_mode() {
  [ -n "${SAVED_MODE:-}" ] || return 0
  kscreen-doctor "output.$OUTPUT.mode.$SAVED_MODE" >/dev/null 2>&1
}

echo "=== Beach Spikers — matched-refresh launcher ==="

# The refresh switch is OFF unless explicitly requested. Matching 50 Hz requires
# dropping the whole desktop to 1920x1080 (the monitor advertises no native
# 2560x1440@50 mode), and Kobayashi rejected that: keep the native mode.
# Trade-off while off: 50 Hz content on a ~60 Hz grid = ~9.9 doubled frames/s.
if [ "${MG_MATCH_REFRESH:-0}" != "1" ]; then
  echo "refresh switch: off (set MG_MATCH_REFRESH=1 to trade native res for 50 Hz)"
  SAVED_MODE=""
else
  SAVED_MODE=$(active_mode_id)
  SAVED_DESC=$(active_mode_desc)
  TARGET_MODE=$(pick_50hz_mode) || TARGET_MODE=""

  if [ -z "$TARGET_MODE" ]; then
    echo "refresh switch: this display advertises no 50 Hz mode, launching as-is"
    SAVED_MODE=""
  elif [ "$TARGET_MODE" = "$SAVED_MODE" ]; then
    echo "refresh switch: already at the 50 Hz mode ($SAVED_DESC), nothing to do"
    SAVED_MODE=""
  else
    TARGET_DESC=$(mode_list | grep "^$TARGET_MODE:" | tr -d '*!')
    echo "refresh switch: $SAVED_DESC -> $TARGET_DESC"
    if kscreen-doctor "output.$OUTPUT.mode.$TARGET_MODE" >/dev/null 2>&1; then
      # KWin applies the mode asynchronously; let it settle before the surface
      # is created or the swapchain is built against the old timing.
      sleep 2
      got=$(qdbus6 org.kde.KWin /KWin supportInformation 2>/dev/null |
              sed -n 's/^Refresh Rate: *//p' | head -1)
      echo "refresh switch: active refresh now ${got:-unknown} mHz"
      trap 'restore_mode' EXIT INT TERM
    else
      echo "refresh switch: mode change failed, launching as-is" >&2
      SAVED_MODE=""
    fi
  fi
fi

# -L: $SO is usually a symlink to module-build/..., so a plain stat reports the
# length of the link target string (30 bytes) rather than the real artifact.
echo "module: $(basename "$SO") ($(stat -Lc%s "$SO") bytes)"
LOG="$DIR/logs/play-$(date +%Y%m%d-%H%M%S).log"
echo "log: $LOG"

# Per-game Wayland app id so the compositor can match this window to the
# launcher's .desktop file (and therefore its icon) instead of grouping every
# ModernGekko title under one hardcoded id. Exported only when the caller has
# not already chosen one.
export MODERNGEKKO_APP_ID=${MODERNGEKKO_APP_ID:-io.github.beachspikers}

# Deliberately NOT detached: this script owns the display mode for as long as
# the game runs, so it must stay attached and restore the mode when the game
# exits (window closed, crash, or Ctrl-C). Detaching would leave the desktop at
# 50 Hz forever.
"$DIR"/lib/ModernGekko/build/moderngekko-run \
  --game "$DIR"/extracted/beach --module "$SO" --wayland "$@" >"$LOG" 2>&1 </dev/null &

pid=$!
echo "pid: $pid"
echo "F1 = settings overlay (pauses game), ESC = close"
echo "----"

wait "$pid"

echo "----"
echo "emulator exited"
restore_mode
if [ -n "${SAVED_DESC:-}" ]; then
  echo "refresh switch: back to $SAVED_DESC"
fi
