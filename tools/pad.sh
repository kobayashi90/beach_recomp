#!/bin/bash
# pad.sh <button> [frames]
#
# Sends a short button press to the running emulator through the automation
# interface: the emulator polls <automation-dir>/commands/ and applies each
# file once. pad_frames holds the button for a frame count and then releases it,
# which is what a real press looks like to the game (a plain pad= state stays
# held until something else changes it).
set -u
A=${AUTOMATION_DIR:-/tmp/mgg}
BTN=${1:?usage: pad.sh <button> [frames]}
FRAMES=${2:-12}
[ -d "$A/commands" ] || { echo "no automation dir at $A"; exit 1; }
printf 'command=pad_frames\nport=0\nframes=%s\n%s=1\n' "$FRAMES" "$BTN" \
  > "$A/commands/$(date +%s%N).cmd"
