#!/bin/bash
export MG_HARNESS=1  # marks this as a measurement instance; killgame.sh refuses to touch an unmarked one
# firstrun-ui.sh -- proves the first-run ROM dialog renders correctly, and that
# it only appears when a new player actually needs it.
#
# Why this exists: the setup card is the first thing somebody who downloads this
# build sees, and it is the one piece of UI that cannot be checked by opening a
# window (there is no Xvfb on this box, and a real window would land on the
# desktop of whoever is at the machine). It is checked from the pixels instead:
#
#   SDL_VIDEODRIVER=offscreen        renders into a real framebuffer, no window
#   MODERNGEKKO_LAUNCHER_SHOT=<path> dumps the first three rendered frames
#   MODERNGEKKO_LAUNCHER_DEBUG=1     logs the card's state and item rectangles
#
# Two independent checks come out of that:
#
#   * OCR of the dumped frame  -- proves the words are on screen and readable,
#     so a missing paragraph or a clipped sentence fails here.
#   * Item rects from the log  -- prove every control is laid out inside the
#     card, so a button pushed off the edge (which is how the in-game menu lost
#     its bottom row before it was split into tabs) fails here too.
#
# Requires: tesseract, ImageMagick. OCR checks are skipped without them; the
# rect and log checks always run.
set -u

DIR=/home/lain/opencode/beach_recomp
BUILD=$DIR/lib/ModernGekko/build
LAUNCHER="$BUILD/Beach Spikers"
WORK=${WORK:-/tmp/opencode/mg-firstrun-ui}

pass=0
fail=0
skip=0
ok()   { echo "  PASS: $*"; pass=$((pass + 1)); }
bad()  { echo "  FAIL: $*"; fail=$((fail + 1)); }
note() { echo "  SKIP: $*"; skip=$((skip + 1)); }

[ -x "$LAUNCHER" ] || { echo "FAIL: no launcher at $LAUNCHER"; exit 1; }

HAVE_OCR=1
for tool in tesseract magick; do
  command -v "$tool" >/dev/null 2>&1 || HAVE_OCR=0
done

rm -rf "$WORK"
mkdir -p "$WORK"

# --- scenario driver --------------------------------------------------------

# scenario <name> <user-dir> <home-dir> [launcher args...]: runs the launcher
# offscreen for a few seconds. The user directory (XDG_DATA_HOME) is where default-game.txt and
# games/ live; HOME is only used for the Documents scan, so the "found these
# images" list is populated from a fake Documents folder rather than the real
# one.
scenario() {
  local name=$1 user=$2 home=$3
  shift 3
  SCEN_DIR=$WORK/$name
  mkdir -p "$SCEN_DIR"
  (
    cd "$BUILD" || exit 1
    XDG_DATA_HOME="$user" HOME="$home" SDL_VIDEODRIVER=offscreen \
      MODERNGEKKO_LAUNCHER_DEBUG=1 MODERNGEKKO_LAUNCHER_SHOT="$SCEN_DIR/frame" \
      timeout 12 "./Beach Spikers" "$@" >"$SCEN_DIR/launcher.log" 2>&1
  )
  local code=$?
  # timeout(1) exits 124 when it had to stop the launcher, which is the expected
  # outcome: the launcher only exits when a player closes it.
  if [ $code -ne 124 ] && [ $code -ne 0 ]; then
    bad "$name: launcher exited with $code"
    return 1
  fi
  return 0
}

# --- OCR side ---------------------------------------------------------------

# matchable: lowercase and strip everything that is not a letter or digit, and
# fold 0/O. OCR reads "ISO" as "IS0" and breaks phrases at line ends, so exact
# substring matching over raw output fails for reasons that have nothing to do
# with the UI. Comparing squashed strings keeps the check meaningful (a word
# still has to be there) without being brittle about punctuation or wrapping.
matchable() {
  tr '[:upper:]' '[:lower:]' | tr '0' 'o' | tr -cd '[:alnum:]'
}

render_text() { # render_text <dir>: OCR the last dumped frame into frame.txt
  local dir=$1
  [ "$HAVE_OCR" = 1 ] || return 0
  # 2x upscale: ImGui's default font at 1x is too small for tesseract, which
  # otherwise only finds the two large heading lines.
  magick "$dir/frame-2.bmp" -resize 200% -colorspace gray -normalize "$dir/frame.png" 2>/dev/null
  tesseract "$dir/frame.png" - --psm 3 2>/dev/null >"$dir/frame.raw"
  matchable <"$dir/frame.raw" >"$dir/frame.txt"
}

want() { # want <dir> <phrase> <label>
  local dir=$1 needle label=${3:-$2}
  needle=$(printf '%s' "$2" | matchable)
  if [ "$HAVE_OCR" = 0 ]; then note "$label (no tesseract)"; return; fi
  if grep -qF -- "$needle" "$dir/frame.txt" 2>/dev/null; then ok "card shows $label"
  else bad "card does not show $label (OCR said: $(tr '\n' ' ' <"$dir/frame.raw" 2>/dev/null | cut -c1-150))"; fi
}
want_not() { # want_not <dir> <phrase> <label>
  local dir=$1 needle label=${3:-$2}
  needle=$(printf '%s' "$2" | matchable)
  if [ "$HAVE_OCR" = 0 ]; then note "no $label (no tesseract)"; return; fi
  if grep -qF -- "$needle" "$dir/frame.txt" 2>/dev/null; then bad "card still shows $label"
  else ok "card does not show $label"; fi
}

# --- layout side ------------------------------------------------------------

# card_rect <dir> <label>: last logged "x y w h" for that item, or exit 1.
card_rect() {
  awk -v want="card item: $2 " '
    index($0, want) {
      x = y = w = h = ""
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^x=/) x = substr($i, 3) + 0
        else if ($i ~ /^y=/) y = substr($i, 3) + 0
        else if ($i ~ /^w=/) w = substr($i, 3) + 0
        else if ($i ~ /^h=/) h = substr($i, 3) + 0
      }
    }
    END { if (x == "" || w == "") exit 1; printf "%d %d %d %d\n", x, y, w, h }
  ' "$1/launcher.log"
}

# card_window <dir>: "W H" of the launcher window, from the card size line.
card_window() {
  sed -n 's/.*window=\([0-9]*\)x\([0-9]*\).*/\1 \2/p' "$1/launcher.log" | tail -1
}

# placed <dir> <label> <description>: the control exists, has a real size, and
# sits fully inside the window.
placed() {
  local dir=$1 label=$2 desc=$3 rect x y w h win win_w win_h
  if ! rect=$(card_rect "$dir" "$label"); then
    bad "$desc is not laid out at all"
    return 1
  fi
  read -r x y w h <<<"$rect"
  if [ "$w" -le 0 ] || [ "$h" -le 0 ]; then
    bad "$desc has an empty rectangle (${w}x${h})"
    return 1
  fi
  win=$(card_window "$dir")
  read -r win_w win_h <<<"${win:-0 0}"
  if [ "$x" -lt 0 ] || [ "$y" -lt 0 ] || [ $((x + w)) -gt "$win_w" ] || [ $((y + h)) -gt "$win_h" ]; then
    bad "$desc is clipped by the window (${x},${y} ${w}x${h} in ${win_w}x${win_h})"
    return 1
  fi
  ok "$desc is on screen at ${x},${y} (${w}x${h})"
  PLACED="$rect"
  return 0
}

log_has() { grep -qF -- "$2" "$1/launcher.log" 2>/dev/null; }
check_log() { # check_log <dir> <needle> <description> [invert]
  if [ -n "${4:-}" ]; then
    if log_has "$1" "$2"; then bad "$3"; else ok "$3"; fi
  else
    if log_has "$1" "$2"; then ok "$3"; else bad "$3"; fi
  fi
}

echo "=== first-run ROM dialog ==="
echo "work: $WORK"

# --- 1. brand new user: empty user directory, nothing in Documents ----------
# The case the dialog exists for. Everything a new player needs has to be on
# screen at once: what this is, what to do, and a way to do it.
if scenario brand-new "$WORK/brand-new/data" "$WORK/brand-new/home"; then
  check_log "$WORK/brand-new" "first-run card opened" "brand new user gets the setup card"
  render_text "$WORK/brand-new"
  want "$WORK/brand-new" "Welcome to"          "the welcome heading"
  want "$WORK/brand-new" "Beach Spikers"       "the product name"
  want "$WORK/brand-new" "Choose your game disc image" "the explanation"
  want "$WORK/brand-new" "no longer needed"    "the 'ISO not needed afterwards' note"
  want "$WORK/brand-new" "Disc image:"         "the disc image field"
  want "$WORK/brand-new" "None selected yet"   "the empty selection state"
  want "$WORK/brand-new" "Pick an ISO"         "the 'pick a file first' hint"
  # The list itself is asserted from the layout log rather than OCR: this
  # heading is dim text drawn over the settings panel behind the card, and
  # tesseract merges it into the background line at the same height. Whether it
  # is laid out at all is the real question, and the log answers it exactly.
  check_log "$WORK/brand-new" "card item: found" \
    "the image list (nothing to list)" invert

  placed "$WORK/brand-new" title  "the heading"
  placed "$WORK/brand-new" choose "the 'choose disc image' button"
  placed "$WORK/brand-new" start  "the start button"
  placed "$WORK/brand-new" hint   "the 'pick a file first' hint"
  placed "$WORK/brand-new" quit   "the quit button"
  # The two buttons share a row with the file picker first: a player reads
  # left-to-right, and Start must not be the thing under their cursor first.
  if choose=$(card_rect "$WORK/brand-new" choose) && start=$(card_rect "$WORK/brand-new" start); then
    read -r cx cy cw ch <<<"$choose"
    read -r sx sy sw sh <<<"$start"
    if [ "$cy" -eq "$sy" ] && [ $((cx + cw)) -le "$sx" ] && [ $((sy + sh)) -le $((cy + ch)) ]; then
      ok "choose sits left of start on the same row"
    else
      bad "choose (${cx},${cy} ${cw}x${ch}) is not left of start (${sx},${sy} ${sw}x${sh})"
    fi
  fi
fi

# --- 2. a disc image already sitting in Documents --------------------------
# Then the card offers it by name instead of making the player hunt through a
# file dialog. The name has to survive rendering: if it is clipped the player
# cannot tell which file they are about to extract.
mkdir -p "$WORK/found-iso/home/Documents/games"
: >"$WORK/found-iso/home/Documents/games/testdisc.iso"
# A second, shallower image proves the recursive scan is not just top-level.
: >"$WORK/found-iso/home/Documents/disc2.iso"
if scenario found-iso "$WORK/found-iso/data" "$WORK/found-iso/home"; then
  check_log "$WORK/found-iso" "first-run card opened" "card opens when only images (no game) exist"
  render_text "$WORK/found-iso"
  placed "$WORK/found-iso" found "the 'found these' heading"
  want "$WORK/found-iso" "testdisc"     "the discovered image filename"
  want "$WORK/found-iso" "disc2"        "a second discovered image"
  # With an image selected, Start becomes usable and the hint disappears.
  placed "$WORK/found-iso" choose "the 'choose disc image' button"
  placed "$WORK/found-iso" start  "the start button"
fi

# --- 3. already set up: the card must stay away ----------------------------
# A returning player has default-game.txt and an extraction; showing the setup
# card again would look like the game forgot them.
GAME_SRC=${GAME_SRC:-$DIR/extracted/beach}
if [ -d "$GAME_SRC" ]; then
  mkdir -p "$WORK/set-up/data/moderngekko"
  printf '%s\n' "$GAME_SRC" >"$WORK/set-up/data/moderngekko/default-game.txt"
  if scenario set-up "$WORK/set-up/data" "$WORK/set-up/home"; then
    check_log "$WORK/set-up" "first-run card opened" "returning player is not asked again" invert
    render_text "$WORK/set-up"
    want_not "$WORK/set-up" "Welcome to" "the setup card"
  fi
else
  note "set-up scenario (no extracted game at $GAME_SRC)"
fi

# --- 4. a stale default-game.txt ------------------------------------------
# The path in the file no longer exists (build moved, or the user directory was
# copied between machines). Falling back to the card is the only sane recovery.
mkdir -p "$WORK/stale/data/moderngekko"
printf '/nonexistent/beach-spikers\n' >"$WORK/stale/data/moderngekko/default-game.txt"
if scenario stale "$WORK/stale/data" "$WORK/stale/home"; then
  check_log "$WORK/stale" "first-run card opened" "a stale default-game.txt falls back to the card"
fi

# --- 5. extraction exists but default-game.txt does not --------------------
# Launching through `moderngekko-run --game ...` from a shell never writes
# default-game.txt, so the game is extracted and remembered by nobody. Asking
# for the ISO again here would be indefensible: the game is already on disk.
if [ -d "$GAME_SRC" ]; then
  mkdir -p "$WORK/discovered/data/moderngekko/games"
  ln -s "$GAME_SRC" "$WORK/discovered/data/moderngekko/games/GBSP8P"
  if scenario discovered "$WORK/discovered/data" "$WORK/discovered/home"; then
    check_log "$WORK/discovered" "found an extracted game without default-game.txt" \
      "an orphaned extraction is discovered"
    check_log "$WORK/discovered" "first-run card opened" \
      "that player is not asked for the ISO again" invert
  fi
else
  note "discovery scenario (no extracted game at $GAME_SRC)"
fi

# --- 6. a disc image opened from a file manager ----------------------------
# Double-clicking an ISO (or dragging one onto the icon) starts the launcher
# with the file as an argument. Making the player find that same file again in
# the dialog would be absurd, so it has to arrive preselected -- and the hint
# telling them to pick a file has to be gone, because they already did.
mkdir -p "$WORK/open-with/home"
: >"$WORK/open-with/home/Chosen Dump.iso"
if scenario open-with "$WORK/open-with/data" "$WORK/open-with/home" \
  "$WORK/open-with/home/Chosen Dump.iso"; then
  check_log "$WORK/open-with" "preselected disc image from the command line" \
    "an image passed on the command line preselects itself"
  render_text "$WORK/open-with"
  want "$WORK/open-with" "Chosen Dump" "the file name it was given"
  want_not "$WORK/open-with" "Pick an ISO" "the 'pick a file first' hint (a file is already selected)"
fi

echo "=== $pass passed, $fail failed, $skip skipped ==="
echo "frames: $WORK/*/frame-2.bmp"
[ "$fail" -eq 0 ] || exit 1