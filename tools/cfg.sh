#!/bin/bash
# cfg.sh [res=N] [vsync=on|off] [immediate=on|off] [present=MODE]
# Edits ModernGekko's GFX.ini in place. Prints the resulting settings.
#
# Sections are not guessable: the loader reads each key from exactly one section
# (Core/Config/GraphicsSettings.cpp) and silently ignores it anywhere else.
# In particular ImmediateXFBEnable lives in [Hacks], NOT [Hardware] -- writing it
# under [Hardware] was a no-op and produced two "identical" A/B runs that were
# then reported as a real measurement. set_key therefore removes the key from
# every other section before writing the correct one.
#
#   InternalResolution        [Settings]  default 1   (2 => 1280x1056 render target)
#   VSync                     [Hardware]  default false
#   ImmediateXFBEnable        [Hacks]     default false
#
# present=MODE does not touch the file: the present mode is a runtime override
# (MODERNGEKKO_PRESENT_MODE=fifo|mailbox|immediate), so callers get a reminder
# instead of a silent no-op.
set -eu
DIR_DATA="$HOME/.local/share/moderngekko"
CFG="$DIR_DATA/Config/GFX.ini"
FRONTEND="$DIR_DATA/config.ini"
[ -f "$CFG" ] || { echo "missing $CFG"; exit 1; }
[ -f "$FRONTEND" ] || { echo "missing $FRONTEND"; exit 1; }

set_key() { # file section key value
  local f=$1 sec=$2 key=$3 val=$4
  local tmp="$f.cfg-tmp"

  # Drop stale copies of the key from sections the loader does not read.
  awk -v want="$sec" -v k="$key" '
    /^\[/ { cur = $0; sub(/^\[/, "", cur); sub(/\]$/, "", cur) }
    index($0, k) == 1 && $0 ~ ("^" k "[ \t]*=") { if (cur != want) next }
    { print }
  ' "$f" >"$tmp" && mv "$tmp" "$f"

  if grep -qxF "[$sec]" "$f"; then
    if grep -qE "^$key[[:space:]]*=" "$f"; then
      sed -i -E "s|^$key[[:space:]]*=.*|$key = $val|" "$f"
    else
      awk -v s="[$sec]" -v k="$key" -v v="$val" '
        { print }
        $0 == s && !done { print k " = " v; done = 1 }
        END { if (!done) { print s; print k " = " v } }' "$f" >"$tmp" && mv "$tmp" "$f"
    fi
  else
    printf '[%s]\n%s = %s\n' "$sec" "$key" "$val" >>"$f"
  fi
}

set_res() { # frontend resolution label, e.g. 1280x720
  local label=$1
  case "$label" in
    1) label=640x528 ;;
    2) label=1280x720 ;;
    3) label=1920x1080 ;;
    4) label=2560x1440 ;;
  esac
  case "$label" in
    640x528|1280x720|1920x1080|2560x1440|3840x2160|5120x2880|7680x4320) ;;
    *) echo "res=$label is not a supported label (640x528 1280x720 1920x1080 2560x1440 3840x2160 5120x2880 7680x4320, or 1/2/3/4)"; exit 2 ;;
  esac

  # FRONTEND_CONFIG is authoritative: ModernGekko reads [Video] resolution from
  # config.ini, maps the label to a Dolphin EFB scale, and writes that scale into
  # GFX.ini itself -- including on shutdown. Editing GFX.ini's InternalResolution
  # alone is therefore undone by the very next run (observed: res=2 -> back to 1).
  set_key "$FRONTEND" Video resolution "$label"

  # Mirror it into GFX.ini so the file on disk matches what the run will use even
  # if something reads it before the frontend syncs.
  case "$label" in
    640x528)   scale=1  ;;
    1280x720)  scale=2  ;;
    1920x1080) scale=3  ;;
    2560x1440) scale=4  ;;
    3840x2160) scale=6  ;;
    5120x2880) scale=8  ;;
    7680x4320) scale=12 ;;
  esac
  set_key "$CFG" Settings InternalResolution "$scale"
}

for arg in "$@"; do
  case "$arg" in
    res=*)        set_res "${arg#res=}" ;;
    vsync=on)     set_key "$CFG" Hardware VSync True ;;
    vsync=off)    set_key "$CFG" Hardware VSync False ;;
    immediate=on) set_key "$CFG" Hacks ImmediateXFBEnable True ;;
    immediate=off) set_key "$CFG" Hacks ImmediateXFBEnable False ;;
    progressive=on)  set_key "$CFG" Hacks ForceProgressive True ;;
    progressive=off) set_key "$CFG" Hacks ForceProgressive False ;;
    present=*)    echo "runtime only, use: MODERNGEKKO_PRESENT_MODE=${arg#present=}" ;;
    *) echo "unknown: $arg"; exit 2 ;;
  esac
done

echo "--- $FRONTEND (authoritative for internal resolution) ---"
grep -E "^resolution" "$FRONTEND"
echo "--- $CFG ---"
cat "$CFG"
