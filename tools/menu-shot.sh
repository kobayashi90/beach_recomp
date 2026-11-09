#!/bin/bash
export MG_HARNESS=1  # marks this as a measurement instance; killgame.sh refuses to touch an unmarked one
# menu-shot.sh -- proves the F1 menu actually *draws* real content, tab by tab.
#
# menu-ui.sh drives the menu and asserts what it *applies*; every one of its
# checks would still pass if the overlay painted a blank rectangle, because it
# reads widget rects from the menu's own log. This harness closes that gap by
# reading the pixels the compositor was handed.
#
# Why a sentinel file and not a frame count: opening the menu pauses emulation
# and the overlay then presents its own frames from another thread, so the
# present index at the moment F1 is pressed depends on how fast the game
# happened to be running. MODERNGEKKO_SWAP_DUMP_GATE makes the dump follow a
# file instead: frames are written only while that file exists, and
# SKIP/MAX/STRIDE count per gate opening rather than for the whole session. So a
# tab gets exactly one frame, with no timing race.
#
# What is asserted, per tab:
#   * every widget the tab submits has glyphs inside its own rect, measured as
#     the count of pixels brighter than the panel (drawn labels 137-557, empty
#     rows 0).
#   * every widget rect fits inside the panel the menu window actually occupies,
#     so a tab cannot silently grow past the bottom of a small window.
#   * the tabs draw *different* pictures (identical ones would mean the
#     click never landed).
#   * the bottom padding of the panel is identical in every tab, i.e. no tab is
#     painting into the window's edge.
#   * the header line is 7-16 px tall, i.e. legible rather than scaled to nothing.
#
# Text is not OCR'd on purpose: the menu renders 16 px glyphs, which is right for
# a 900x492 window and far below what tesseract reads reliably. Attempting it
# produced confident nonsense ("REACE SIFERS"), so legibility is measured as
# glyph height and presence instead.
set -u

DIR=/home/lain/opencode/beach_recomp
RUN=${RUN:-$DIR/lib/ModernGekko/build/moderngekko-run}
WORK=${WORK:-/tmp/opencode/mg-menu-shot}
GATE=$WORK/gate
FRAMES=$WORK/frames
AUTO=$WORK/auto

pass=0
fail=0
skip=0
ok()   { echo "  PASS: $*"; pass=$((pass + 1)); }
bad()  { echo "  FAIL: $*"; fail=$((fail + 1)); }
note() { echo "  SKIP: $*"; skip=$((skip + 1)); }

[[ -x $RUN ]] || { echo "FAIL: no runner at $RUN"; exit 1; }
if ! command -v magick >/dev/null 2>&1; then
  echo "FAIL: ImageMagick (magick) is required to read the captured frames"
  exit 1
fi

SO=$(ls -1d "$DIR"/build/modules/GBSP8P/*/gGBSP8P_recomp.so 2>/dev/null | head -1)
[[ -n $SO ]] || { echo "FAIL: no game module in build/modules/GBSP8P"; exit 1; }

rm -rf "$WORK"
mkdir -p "$FRAMES" "$AUTO/commands"

LOG=$WORK/menu.log
F1=0xFFBE
ESC=0xFF1B
seq=0

cmd() { # cmd <name> <line>... -- one automation command per file, batched per tick
  local name=$1
  shift
  seq=$((seq + 1))
  printf '%s\n' "$@" >"$AUTO/commands/$(printf '%03d' "$seq")-$name.txt"
}

field() { sed -n 's/^'"$1"'=//p' "$AUTO/status.txt" 2>/dev/null | head -1; }

wait_state() { # wait_state <state> <seconds>
  local i
  for ((i = 0; i < $2 * 10; i++)); do
    [[ $(field state) == "$1" ]] && return 0
    sleep 0.1
  done
  return 1
}

# rect <kind> <name> -> "x y w h" of the newest submission of that item. Widget
# names are unique per tab, so the newest occurrence is always the frame of the
# tab that is currently open.
rect() {
  tac "$LOG" 2>/dev/null | grep -F -m1 " $1=$2 " |
    sed -n 's/.* x=\([-0-9]*\) y=\([-0-9]*\) w=\([-0-9]*\) h=\([-0-9]*\).*/\1 \2 \3 \4/p'
}

wait_rect() { # wait_rect <kind> <name> <seconds> -> "x y w h"
  local i out
  for ((i = 0; i < $3 * 10; i++)); do
    out=$(rect "$1" "$2")
    [[ -n $out ]] && { echo "$out"; return 0; }
    sleep 0.1
  done
  return 1
}

newest_frame() { ls -1t "$FRAMES"/swap-*.pgm 2>/dev/null | head -1; }

# capture <label>: open the gate for a moment and return the frame it produced.
capture() {
  local before after i
  before=$(newest_frame)
  : >"$GATE"
  for ((i = 0; i < 40; i++)); do
    after=$(newest_frame)
    [[ -n $after && $after != "$before" ]] && break
    sleep 0.1
  done
  # Leave a moment for any second frame of the burst, then take the newest.
  sleep 0.2
  rm -f "$GATE"
  newest_frame
}

# ink <frame> <x> <y> <w> <h> -> number of pixels brighter than the panel.
#
# Standard deviation was the wrong statistic here: a widget's label is a short
# word inside a control that can be 580 px wide, so a perfectly drawn label
# averaged out to std 16-18 while a blank row of the same width read 3.5. That
# left no margin between "drawn" and "not drawn", and the first honest luma
# reading (the swapchain is RGB10_A2, so the old byte plane was meaningless)
# landed on the wrong side of it. Counting ink pixels instead is unambiguous:
# the menu panel is uniformly dark, so every glyph pixel stands far above it.
# Measured: labels 137-557 px, empty panel rows 0.
ink() {
  magick "$1" -crop "$4"x"$5"+"$2"+"$3" +repage -depth 8 gray:- 2>/dev/null |
    od -An -tu1 -v | awk '{for (i = 1; i <= NF; i++) if ($i > 90) n++} END {print n + 0}'
}

# row_profile <frame> <x> <y> <w> <h> -> per-row mean luma, one value per line.
row_profile() {
  magick "$1" -crop "$4"x"$5"+"$2"+"$3" +repage -resize "1x${5}!" -depth 8 gray:- |
    od -An -tu1 -v | tr -s ' ' '\n' | sed '/^$/d'
}

echo "=== F1 menu renders real content ==="
echo "work: $WORK"

tools/killgame.sh >/dev/null 2>&1
sleep 1
MODERNGEKKO_MENU_DEBUG=1 \
MODERNGEKKO_SWAP_DUMP=/dev/null \
MODERNGEKKO_SWAP_DUMP_FILES="$FRAMES" \
MODERNGEKKO_SWAP_DUMP_GATE="$GATE" \
MODERNGEKKO_SWAP_DUMP_MAX=1 \
  setsid nohup "$RUN" --game "$DIR"/extracted/beach --module "$SO" --wayland \
  --automation-dir "$AUTO" >"$LOG" 2>&1 </dev/null &
for _ in $(seq 1 30); do
  [[ -f $AUTO/status.txt ]] && break
  sleep 1
done
[[ -f $AUTO/status.txt ]] || { echo "FAIL: the runner never booted, see $LOG"; exit 1; }
sleep 8

cmd open "command=hotkey" "keysym=$F1"
if wait_state paused 12; then ok "the menu opened and paused the core"; else bad "the menu did not pause the core"; fi
sleep 1

# The tab bar's y is where the tab items are submitted; the header text sits
# above it. Both come from the menu's own rect log rather than from hardcoded
# geometry, so this keeps working if the layout moves.
tab_rect() { # tab_rect <label> -> x y w h, ignoring look-alike rects elsewhere
  tac "$LOG" 2>/dev/null | grep -F " tab=$1 " |
    sed -n 's/.* x=\([-0-9]*\) y=\([-0-9]*\) w=\([-0-9]*\) h=\([-0-9]*\).*/\1 \2 \3 \4/p' |
    awk '$3 > 20 && $3 < 200 { print; exit }'
}

# The widget each tab must submit before it is considered switched: a tab click
# that silently missed would be caught here rather than producing a duplicate
# picture that only shows up later.
declare -A EXPECT=(
  [Display]="resolution backend fullscreen vsync aspect widescreen showfps"
  [Input]="rescan port0"
  [Audio]="audio"
  [Textures]="hires hirecache rescan-textures create-textures"
  [States]="slot savestate loadstate reset screenshot"
  [Cheats]="enable-cheats"
  [System]="language region saveconfig restart quit"
)
TABS=(Display Input Audio Textures States Cheats System)

declare -A SHOT=()
declare -A HASH=()
# Left-clicks a tab header and returns once its signature widget exists.
#
# The pause between press and release is not cosmetic: ImGui only counts a click
# when it has seen the button down on an earlier frame, so both events in one
# automation tick are lost. It is also the harness's weak point -- these clicks
# land on Kobayashi's live desktop, and a real mouse moving over the window
# overrides the automation's position. That produces a press at the tab and a
# release half a screen away, which ImGui (correctly) refuses to call a click.
# One such sweep is what made this suite fail on the Textures tab while every
# other tab passed. Hence the retry: a missed click is re-issued from scratch.
click_tab() { # click_tab <label> -> 0 once the tab's signature widget is up
  local tab=$1 try tx ty tw th cx cy first_widget
  first_widget=${EXPECT[$tab]%% *}
  for try in 1 2 3; do
    read -r tx ty tw th <<<"$(tab_rect "$tab")"
    [[ -n ${tx:-} ]] || return 1
    cx=$((tx + tw / 2))
    cy=$((ty + th / 2))
    cmd "$tab-move-$try" "command=mouse" "x=$cx" "y=$cy"
    sleep 0.15
    cmd "$tab-down-$try" "command=mouse" "x=$cx" "y=$cy" "button=0" "down=1"
    sleep 0.25
    cmd "$tab-up-$try" "command=mouse" "x=$cx" "y=$cy" "button=0" "down=0"
    sleep 0.6
    # Waiting for the signature widget keeps the capture from catching the
    # previous tab's picture.
    wait_rect widget "$first_widget" 4 >/dev/null && return 0
    [[ $try -lt 3 ]] && note "$tab: click missed (a real pointer moved mid-click?), retrying"
  done
  return 1
}

for tab in "${TABS[@]}"; do
  if [[ -z $(tab_rect "$tab") ]]; then
    bad "$tab: no rect was ever submitted"
    continue
  fi
  if ! click_tab "$tab"; then
    bad "$tab: clicking it did not bring up widget '${EXPECT[$tab]%% *}'"
    continue
  fi
  sleep 0.4

  frame=$(capture "$tab")
  if [[ -z $frame ]]; then bad "$tab: no frame was captured"; continue; fi
  SHOT[$tab]=$frame
  HASH[$tab]=$(magick "$frame" -crop 720x472+90+10 +repage -format "%#" info: 2>/dev/null)
  ok "$tab: captured $(basename "$frame")"
done

[[ -n ${SHOT[Display]:-} ]] || { echo "=== nothing captured, aborting ==="; tail -5 "$LOG"; exit 1; }

# --- 1. every widget of every tab has glyphs inside its own rect ------------
echo "  -- widget text --"
for tab in "${TABS[@]}"; do
  frame=${SHOT[$tab]:-}
  [[ -n $frame ]] || continue
  have=0
  missing=""
  for widget in ${EXPECT[$tab]}; do
    read -r wx wy ww wh <<<"$(rect widget "$widget")"
    [[ -n ${wx:-} ]] || { missing+=" $widget(no-rect)"; continue; }
    # The whole control is probed, not just its left edge: a combo's label sits
    # at the left but a button's text is centred, and either way the control's
    # own frame contributes nothing bright enough to be mistaken for glyphs.
    n=$(ink "$frame" "$wx" "$wy" "$ww" "$wh")
    if [[ ${n:-0} -ge 40 ]]; then
      have=$((have + 1))
    else
      missing+=" $widget(ink=$n)"
    fi
  done
  total=$(echo ${EXPECT[$tab]} | wc -w)
  if [[ -z $missing ]]; then
    ok "$tab: all $total widgets have drawn text"
  else
    bad "$tab: no text drawn for:$missing"
  fi
done

# --- 2. every tab is a different picture -----------------------------------
echo "  -- distinct tabs --"
distinct=$(printf '%s\n' "${HASH[@]}" | sort -u | wc -l)
if [[ $distinct -eq ${#TABS[@]} ]]; then
  ok "all ${#TABS[@]} tabs render different content"
else
  bad "only $distinct of ${#TABS[@]} tabs rendered different content (a tab click missed)"
fi

# --- 3. the content fits inside the panel ---------------------------------
# The menu is height-clamped on purpose (it has to fit whatever backbuffer the
# game window has), and a tab that grew past the window would silently lose its
# bottom rows -- that is exactly how savestates used to become unclickable. Every
# rect the menu submits is therefore checked against the window it claims to be
# drawing into, using the same clamping arithmetic the menu uses.
echo "  -- fits inside the panel --"
read -r frame_w frame_h <<<"$(sed -n 2p "${SHOT[Display]}" | awk '{print $1, $2}')"
win_w=$((frame_w - 20 > 720 ? 720 : frame_w - 20))
win_h=$((frame_h - 20 > 560 ? 560 : frame_h - 20))
win_left=$(((frame_w - win_w) / 2))
win_top=$(((frame_h - win_h) / 2))
win_right=$((win_left + win_w))
win_bottom=$((win_top + win_h))
checked=0
outside=""
for tab in "${TABS[@]}"; do
  for widget in ${EXPECT[$tab]}; do
    read -r wx wy ww wh <<<"$(rect widget "$widget")"
    [[ -n ${wx:-} ]] || continue
    checked=$((checked + 1))
    if ((wx < win_left || wy < win_top || wx + ww > win_right || wy + wh > win_bottom)); then
      outside+=" $tab/$widget(${wx},${wy} ${ww}x${wh})"
    fi
  done
done
if [[ -z $outside ]]; then
  ok "all $checked widget rects fit inside the ${win_w}x${win_h} panel"
else
  bad "widgets fall outside the panel:$outside"
fi

# --- 4. nothing spills into the panel's bottom padding ---------------------
# The panel is translucent, so the paused game shows through its empty part and
# a "this area is flat" test would be meaningless. What is reliable is that this
# band is *the same* in every tab: whatever is there is the game plus the panel
# tint, so if any tab painted into the bottom padding its picture could not
# match the others.
echo "  -- no spill at the bottom edge --"
pad_top=$((win_bottom - 12))
pad_h=$((win_bottom - pad_top - 2))
if [[ $pad_h -ge 6 ]]; then
  declare -A pad=()
  for tab in "${TABS[@]}"; do
    [[ -n ${SHOT[$tab]:-} ]] || continue
    pad[$tab]=$(magick "${SHOT[$tab]}" -crop $((win_w - 40))x"$pad_h"+$((win_left + 20))+"$pad_top" \
      +repage -format "%#" info: 2>/dev/null)
  done
  common=$(printf '%s\n' "${pad[@]}" | sort | uniq -c | sort -rn | head -1 | awk '{print $2}')
  spilled=""
  for tab in "${!pad[@]}"; do
    [[ ${pad[$tab]} == "$common" ]] || spilled+=" $tab"
  done
  if [[ -z $spilled ]]; then
    ok "the panel's bottom padding is untouched in every tab"
  else
    bad "content reaches the bottom padding in:$spilled"
  fi
else
  note "bottom-padding probe (panel too short)"
fi

# --- 4. the header line is legible ----------------------------------------
# Measured as the number of rows in the header band that carry ink, counted
# against the band's own background level rather than a fixed direction: the
# panel is dark and glyphs are bright, but hardcoding "ink pulls the row mean
# down" is exactly the assumption that made this check report 22 rows when the
# real text occupied 8. The band also stops short of the tab bar, whose
# separator line is bright enough to look like a whole row of text.
echo "  -- legibility --"
frame=${SHOT[Display]}
read -r tx ty tw th <<<"$(tab_rect Display)"
band_top=$((ty - 24))
band_h=$((ty - band_top - 6))
if [[ $band_h -ge 8 ]]; then
  rows=0
  mode=0
  # uniq -c emits "<count> <value>"; the most frequent row level is the panel
  # background, and any row that departs from it carries ink.
  while read -r count mean; do
    mode=$mean
    break
  done < <(row_profile "$frame" 98 "$band_top" 700 "$band_h" | sort -n | uniq -c | sort -rn)
  while read -r value; do
    d=$((value > mode ? value - mode : mode - value))
    [[ $d -ge 5 ]] && rows=$((rows + 1))
  done < <(row_profile "$frame" 98 "$band_top" 700 "$band_h")
  if [[ $rows -ge 7 && $rows -le 16 ]]; then
    ok "the header line is $rows px tall (legible, inside its band)"
  else
    bad "the header line is $rows px tall (expected 7-16)"
  fi
else
  note "header legibility (no band above the tab bar)"
fi

# --- 5. the dump follows the gate -----------------------------------------
# If the gate were ignored, every burst would write a frame and this count would
# run into the hundreds.
frames=$(ls -1 "$FRAMES"/swap-*.pgm 2>/dev/null | wc -l)
if [[ $frames -le $(( ${#TABS[@]} * 3 )) ]]; then
  ok "the gate limited capture to $frames frames for ${#TABS[@]} tabs"
else
  bad "the gate did not limit capture ($frames frames written)"
fi

tools/killgame.sh >/dev/null 2>&1

echo "=== $pass passed, $fail failed, $skip skipped ==="
echo "frames: $FRAMES"
[[ $fail -eq 0 ]] || exit 1
