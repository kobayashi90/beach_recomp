#!/bin/bash
export MG_HARNESS=1  # marks this as a measurement instance; killgame.sh refuses to touch an unmarked one
# menu-ui.sh -- proves the F1 menu applies settings LIVE, driven through the
# real ImGui widget path (no restart, no direct calls into the apply helpers).
#
# How the clicks work: the overlay runs inside the game window, so the harness
# cannot guess where a widget is. With MODERNGEKKO_MENU_DEBUG=1 the menu logs the
# screen rect of every widget and popup item it submits, plus the pointer
# position ImGui sees and whether it reports the item as hovered:
#
#   [menu-ui] f=<frame> widget=resolution x=.. y=.. w=.. h=.. hover=0|1
#   [menu-ui] f=<frame> item=port0/Keyboard (Cherry ...) x=.. y=.. ...
#   [menu-ui] f=<frame> mouse x=.. y=.. down=0|1
#
# The harness reads those rects, moves the pointer, WAITS UNTIL IMGUI CONFIRMS
# THE HOVER and only then presses the button. That matters because a combo popup
# is height-limited and clipped: an item outside the visible part still gets
# submitted (and logged) but can never be hovered, so a blind coordinate click
# would either miss or hit a different row.
#
# Input goes through the automation protocol's `mouse` command, which feeds the
# same Presenter::SetMousePos/SetMousePress path as a physical pointer. Down and
# up are separate command files on purpose: commands are batched per automation
# tick, and ImGui treats a button that goes down and up inside one frame as no
# click at all.
#
# Assertions read "[menu-live] ..." lines, which the RUNNING core prints from
# g_ActiveConfig / the pad's resolved device -- never the menu's own copy of the
# settings. A green run therefore means the change really reached the emulator.
set -u

DIR=/home/lain/opencode/beach_recomp
DATA="$HOME/.local/share/moderngekko"
F1=0xFFBE
ESC=0xFF1B
RUN="$DIR/lib/ModernGekko/build/moderngekko-run"
SO=${MODULE:-$(ls -d "$DIR"/build/modules/GBSP8P/*/gGBSP8P_recomp.so 2>/dev/null | head -1)}
[ -z "$SO" ] && { echo "FAIL: no module .so"; exit 1; }

pass=0
fail=0
seq=0
ok()  { echo "  PASS: $*"; pass=$((pass + 1)); }
bad() { echo "  FAIL: $*"; fail=$((fail + 1)); }
# Informational only: a skipped probe is neither a pass nor a fail, so note()
# must not touch the counters. It exists because the two "we cannot run this
# section" branches used to call an undefined helper and printed
# "command not found" to stderr while the script happily carried on.
note() { echo "  NOTE: $*"; }

field() { sed -n "s/^$1=//p" "$AUTO/status.txt" 2>/dev/null | head -1; }

# config.ini is written as "key = value" by the frontend's Save() (and as
# "key=value" by hand edits), so match both. A plain "key=" match silently
# returned nothing once, which made a live-apply assertion pass for the wrong
# reason.
ini_get() { # ini_get <key>
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$DATA/config.ini" |
    head -1
}

cmd() { # cmd <name> <line>...
  local name=$1
  shift
  seq=$((seq + 1))
  printf '%s\n' "$@" >"$AUTO/commands/$(printf '%03d' "$seq")-$name.txt"
}

# Only lines written after mark() count for the following assertions: grepping
# the whole log let "efb_scale=2" pass on the boot line even though no click had
# applied anything.
mark() { MARK=$(wc -l <"$LOG" 2>/dev/null || echo 0); }
grep_since() { tail -n +"$((MARK + 1))" "$LOG" 2>/dev/null | grep -q -- "$1"; }
grep_since_text() { tail -n +"$((MARK + 1))" "$LOG" 2>/dev/null | grep -- "$1"; }

wait_state() { # wait_state <state> <seconds>
  local want=$1 limit=$2 i
  for ((i = 0; i < limit * 10; i++)); do
    [ "$(field state)" = "$want" ] && return 0
    sleep 0.1
  done
  return 1
}

# rect <kind> <name> -> "x y w h" from the most recent submission of that item.
# Names contain spaces and slashes (device names), so match the literal
# " kind=name " and take the newest line (the log grows every frame).
rect() {
  tac "$LOG" 2>/dev/null | grep -F -m1 " $1=$2 " |
    sed -n 's/.* x=\([-0-9]*\) y=\([-0-9]*\) w=\([-0-9]*\) h=\([-0-9]*\).*/\1 \2 \3 \4/p'
}

wait_rect() { # wait_rect <kind> <name> <seconds>
  local i out
  for ((i = 0; i < $3 * 10; i++)); do
    out=$(rect "$1" "$2")
    [ -n "$out" ] && { echo "$out"; return 0; }
    sleep 0.1
  done
  return 1
}

hovered() { # hovered <kind> <name> -- ImGui reports the pointer on it
  local last
  last=$(tac "$LOG" 2>/dev/null | grep -F -m1 " $1=$2 ")
  [[ "$last" == *hover=1* ]]
}

move_to() { cmd "$3-move" "command=mouse" "x=$1" "y=$2"; }

press() { # press <x> <y> <label>
  cmd "$3-down" "command=mouse" "x=$1" "y=$2" "button=0" "down=1"
  sleep 0.25
  cmd "$3-up" "command=mouse" "x=$1" "y=$2" "button=0" "down=0"
  sleep 0.4
}

hover_seq=0
HOVER_X=0
HOVER_Y=0

# try_hover <kind> <name> -- move onto the item and wait for ImGui to confirm it.
# Returns 1 (without counting a failure) when the item is clipped/unhoverable, so
# candidate lists can be probed in order.
try_hover() {
  local kind=$1 name=$2 r x y w h i
  r=$(rect "$kind" "$name")
  [ -z "$r" ] && return 1
  read -r x y w h <<<"$r"
  HOVER_X=$((x + w / 2))
  HOVER_Y=$((y + h / 2))
  hover_seq=$((hover_seq + 1))
  move_to "$HOVER_X" "$HOVER_Y" "h$hover_seq"
  for ((i = 0; i < 15; i++)); do
    hovered "$kind" "$name" && return 0
    # Re-issue the move every half second. These clicks land on a live desktop,
    # and a real mouse moving over the window overrides the automation's
    # position, so a single move can lose the pointer entirely (seen: the
    # pointer dragged 500 px away and out of the window). Re-asserting costs
    # nothing and gives the harness another chance instead of failing.
    if ((i % 5 == 4)); then
      hover_seq=$((hover_seq + 1))
      move_to "$HOVER_X" "$HOVER_Y" "h$hover_seq"
    fi
    sleep 0.1
  done
  return 1
}

click_item() { # click_item <kind> <name> <label> -- hover-verified click
  local kind=$1 name=$2 label=$3
  if ! try_hover "$kind" "$name"; then
    bad "$kind=$name never hovered"
    return 1
  fi
  ok "hover confirmed on $kind=$name at $HOVER_X,$HOVER_Y"
  press "$HOVER_X" "$HOVER_Y" "$label"
}

# Names of the items under a prefix, from the NEWEST frame that logged any of
# them (older frames are a different popup layout), as "y<TAB>name" sorted
# top-down. Only names visible to ImGui in that frame are useful; the callers
# probe them with try_hover().
items_by_y() { # items_by_y <prefix>
  awk -v p=" item=$1" '
    index($0, p) == 0 { next }
    {
      if (!match($0, / f=[0-9]+ /)) next
      f = substr($0, RSTART + 3, RLENGTH - 4) + 0
      i = index($0, p) + length(p)
      rest = substr($0, i)
      j = index(rest, " x=")
      if (j == 0) next
      name = substr(rest, 1, j - 1)
      if (!match($0, / y=-?[0-9]+ /)) next
      y = substr($0, RSTART + 3, RLENGTH - 4) + 0
      if (f > maxf) { maxf = f; n = 0; delete seen; delete out }
      if (f == maxf && !(name in seen)) { seen[name] = 1; out[++n] = y "\t" name }
    }
    END { for (k = 1; k <= n; k++) print out[k] }
  ' "$LOG" 2>/dev/null | sort -n
}

# dismiss_popup: ESC straight into the ImGui context (command=key deliberately
# does not run the hotkey callback), so an open combo popup closes without
# closing the menu. A popup left open blocks hovering on everything behind it,
# which used to cascade into unrelated failures.
dismiss_popup() {
  cmd "$1-esc-down" "command=key" "keysym=0x1B" "down=1"
  sleep 0.1
  cmd "$1-esc-up" "command=key" "keysym=0x1B" "down=0"
  sleep 0.4
}

launch() { # launch <label> [game_dir] [module]
  # The disc and the recompiled module are a pair, so a region probe has to be
  # able to hand in both: GBSE8P's .so only runs against extracted/beach-us,
  # and pointing the PAL module at the US disc would recompile nothing and
  # mis-load the game ini. Every other section wants the PAL pair, so the
  # arguments default to it and the old one-argument calls stay valid.
  local game=${2:-"$DIR"/extracted/beach}
  local mod=${3:-$SO}
  AUTO=/tmp/mgmenu-ui-$1
  rm -rf "$AUTO"
  mkdir -p "$AUTO/commands"
  LOG="$DIR/logs/menu-ui-$1-$(date +%H%M%S).log"
  MODERNGEKKO_MENU_DEBUG=1 setsid nohup "$RUN" \
    --game "$game" --module "$mod" --wayland \
    --automation-dir "$AUTO" >"$LOG" 2>&1 </dev/null &
  for _ in $(seq 1 30); do
    [ -f "$AUTO/status.txt" ] && break
    sleep 1
  done
  [ -f "$AUTO/status.txt" ] || { bad "boot ($1), see $LOG"; return 1; }
  sleep 8
}

BACKUP=/tmp/mgmenu-ui-backup
# Set by the States-tab section: a savestate the harness wrote and a screenshot
# it asked for. A pre-existing savestate in the same slot is copied to the backup
# directory and put back, so a real state is never clobbered by a test run.
state_written=""
state_backup=""
state_slot=""
shot_written=""
cleanup_states() {
  if [ -n "$state_written" ]; then
    if [ -n "$state_backup" ] && [ -f "$state_backup" ]; then
      cp "$state_backup" "$state_written" 2>/dev/null || true
    else
      rm -f "$state_written"
    fi
  fi
  [ -n "$shot_written" ] && rm -f "$shot_written"
}
restore_files() {
  [ -f "$BACKUP/GCPadNew.ini" ] && cp "$BACKUP/GCPadNew.ini" "$DATA/Config/GCPadNew.ini"
  [ -f "$BACKUP/config.ini" ] && cp "$BACKUP/config.ini" "$DATA/config.ini"
  # The cheats test writes Dolphin's per-game ini; the directory usually does
  # not exist at all, so "no backup" means "delete what the test created".
  if [ -d "$DATA/GameSettings" ]; then
    rm -rf "$DATA/GameSettings"
    [ -d "$BACKUP/GameSettings" ] && cp -a "$BACKUP/GameSettings" "$DATA/GameSettings"
  fi
  cleanup_states
}

"$DIR/tools/killgame.sh" >/dev/null 2>&1
sleep 1
mkdir -p "$BACKUP"
cp "$DATA/Config/GCPadNew.ini" "$BACKUP/GCPadNew.ini" 2>/dev/null || true
cp "$DATA/config.ini" "$BACKUP/config.ini" 2>/dev/null || true
[ -d "$DATA/GameSettings" ] && cp -a "$DATA/GameSettings" "$BACKUP/GameSettings"
trap restore_files EXIT

echo "=== F1 menu live-apply regression ==="
# Which backbuffer the suite runs in, and which resolution the live-apply test
# switches to. RES_BASE=640x528 runs everything at this box's real setting: the
# menu window is clamped to the backbuffer, so a widget pushed past the bottom
# edge is simply unclickable there (that is what forced the States tab split).
RES_BASE=${RES_BASE:-1280x720}
RES_ALT=${RES_ALT:-640x528}
scale_of() { # scale_of <resolution preset> -> InternalResolution scale
  case "$1" in
    640x528) echo 1 ;;
    1280x720) echo 2 ;;
    *) echo 1 ;;
  esac
}
RES_BASE_SCALE=$(scale_of "$RES_BASE")
RES_ALT_SCALE=$(scale_of "$RES_ALT")
# Start from a known state: the base resolution is what the live-apply test
# changes away from and back to, so the assertion cannot be vacuous.
# The box's own resolution is captured BEFORE anything is forced, so the final
# check can prove the run put it back. (Asserting a fixed value here was wrong:
# the script forces one for its own test and then restores the backup.)
res_original=$(ini_get resolution)
[ -n "$res_original" ] || res_original=$RES_BASE
bash "$DIR/tools/cfg.sh" res=$RES_BASE >/dev/null 2>&1 || true
cfg_before=$(ini_get resolution)
[ "$cfg_before" = "$RES_BASE" ] && ok "starting resolution $RES_BASE" \
  || bad "could not set $RES_BASE before launch (config says '$cfg_before')"

# enable_cheats persists in config.ini and is captured by the backup above, so
# whatever the box was left in becomes the state every later run "restores".
# The master-switch assertion clicks the box exactly once and expects to turn it
# ON: when the key is already true that click turns cheats *off*, which inverts
# the whole section -- the first apply reads enabled=0, the AR code never runs
# because the handler is disabled, and the "switch it back off" click reports
# enabled=1. Pin it off after the backup so the click is always the same
# transition, and the final restore still puts the player's own value back.
cheats_original=$(ini_get enable_cheats)
if grep -q '^enable_cheats=' "$DATA/config.ini"; then
  sed -i 's|^enable_cheats=.*|enable_cheats=false|' "$DATA/config.ini"
else
  printf 'enable_cheats=false\n' >> "$DATA/config.ini"
fi
[ "$(ini_get enable_cheats)" = "false" ] \
  && ok "enable_cheats pinned off before boot (was '${cheats_original:-unset}')" \
  || bad "could not pin enable_cheats off (now '$(ini_get enable_cheats)')"

launch main || exit 1
ok "boot: $(field state), speed $(field speed)"

# --- open the menu ------------------------------------------------------
cmd open "command=hotkey" "keysym=$F1"
sleep 2
if wait_state paused 5; then ok "menu open (core paused)"; else bad "menu did not pause the core"; fi
if wait_rect tab Display 5 >/dev/null; then ok "widget geometry logged"; else bad "no [menu-ui] geometry in the log"; fi
tab_count=$(grep -o " tab=[A-Za-z]* " "$LOG" | sort -u | wc -l)
[ "$tab_count" -eq 7 ] && ok "all seven tabs reported" || bad "tabs reported: $tab_count"

# --- change internal resolution LIVE -----------------------------------
click_item widget resolution res || exit 1
sleep 0.4
wait_rect item resolution/$RES_ALT 5 >/dev/null && ok "resolution popup opened" \
  || bad "resolution popup did not open"
mark
click_item item resolution/$RES_ALT res-alt || true
sleep 0.4
grep_since "\[menu\] display applied: scale=$RES_ALT_SCALE" \
  && ok "resolution applied through the live path (scale=$RES_ALT_SCALE)" \
  || bad "no live display apply logged"

# --- close and prove the CORE picked it up -----------------------------
cmd close "command=hotkey" "keysym=$ESC"
sleep 1
if wait_state running 5; then ok "menu closed (core running)"; else bad "menu did not resume the core"; fi
for _ in $(seq 1 40); do
  grep_since "\[menu-live\] efb_scale=$RES_ALT_SCALE " && break
  sleep 0.25
done
grep_since "\[menu-live\] efb_scale=$RES_ALT_SCALE " \
  && ok "running core reports efb_scale=$RES_ALT_SCALE without a restart" \
  || bad "core never reported efb_scale=$RES_ALT_SCALE (last: $(grep '\[menu-live\]' "$LOG" | tail -1))"
cfg_now=$(ini_get resolution)
[ "$cfg_now" = "$RES_ALT" ] && ok "config.ini persisted $RES_ALT" \
  || bad "config.ini says '$cfg_now'"

# Every apply helper prints one line; assertions read the LAST one since the
# current mark, so a click that logs nothing cannot inherit an older pass.
apply_line() { grep_since_text "$1" | tail -1; }

aspect_mode_of() { # aspect_mode_of <config.ini value> -> AspectMode
  case "$1" in
    16:9) echo 1 ;;
    4:3) echo 2 ;;
    stretch) echo 3 ;;
    raw) echo 6 ;;
    *) echo 0 ;;
  esac
}

# --- aspect ratio, live (Display tab) ----------------------------------
# The starting value is read from config.ini, so the check works whatever the
# box happens to be set to, and picks a target that differs from it.
orig_aspect=$(ini_get aspect_ratio)
[ -n "$orig_aspect" ] || orig_aspect=auto
orig_aspect_mode=$(aspect_mode_of "$orig_aspect")
case "$orig_aspect" in
  16:9) alt_aspect=4:3 ;;
  *) alt_aspect=16:9 ;;
esac
alt_aspect_mode=$(aspect_mode_of "$alt_aspect")

cmd aspect-open "command=hotkey" "keysym=$F1"
sleep 2
wait_state paused 5 >/dev/null
click_item tab Display display-tab-aspect || true
sleep 0.5
mark
click_item widget aspect aspect-combo || true
sleep 0.5
click_item item "aspect/$alt_aspect" aspect-item || true
sleep 0.5
if apply_line '\[menu\] display applied: ' | grep -q "aspect=$alt_aspect_mode "; then
  ok "aspect $alt_aspect went through the live apply path"
else
  bad "aspect has no live apply (last: $(apply_line '\[menu\] display applied: '))"
fi
cmd aspect-close "command=hotkey" "keysym=$ESC"
sleep 1
wait_state running 5 >/dev/null
for _ in $(seq 1 40); do
  grep_since "aspect=$alt_aspect_mode widescreen=" && break
  sleep 0.25
done
grep_since "aspect=$alt_aspect_mode widescreen=" \
  && ok "running core reports aspect=$alt_aspect_mode without a restart" \
  || bad "core never reported aspect=$alt_aspect_mode (last: $(grep '\[menu-live\]' "$LOG" | tail -1))"

# --- widescreen hack, live, and put the display extras back -----------
orig_wide=$(ini_get widescreen_hack)
[ -n "$orig_wide" ] || orig_wide=false
if [ "$orig_wide" = "true" ]; then alt_wide=0; alt_wide_name=false; orig_wide_num=1
else alt_wide=1; alt_wide_name=true; orig_wide_num=0; fi

cmd wide-open "command=hotkey" "keysym=$F1"
sleep 2
wait_state paused 5 >/dev/null
click_item tab Display display-tab-wide || true
sleep 0.5
mark
click_item widget widescreen widescreen-checkbox || true
sleep 0.5
if apply_line '\[menu\] display applied: ' | grep -q "widescreen=$alt_wide show_fps="; then
  ok "widescreen hack went through the live apply path"
else
  bad "widescreen has no live apply (last: $(apply_line '\[menu\] display applied: '))"
fi
now_wide=$(ini_get widescreen_hack)
[ "$now_wide" = "$alt_wide_name" ] && ok "config.ini persisted widescreen_hack=$alt_wide_name" \
  || bad "config.ini says widescreen_hack='$now_wide'"

# Undo both, still in this session, and prove the core follows on resume.
mark
click_item widget widescreen widescreen-back || true
sleep 0.4
mark
click_item widget aspect aspect-combo-back || true
sleep 0.5
click_item item "aspect/$orig_aspect" aspect-back || true
sleep 0.5
cmd wide-close "command=hotkey" "keysym=$ESC"
sleep 1
wait_state running 5 >/dev/null
for _ in $(seq 1 40); do
  grep_since "aspect=$orig_aspect_mode widescreen=$orig_wide_num" && break
  sleep 0.25
done
grep_since "aspect=$orig_aspect_mode widescreen=$orig_wide_num" \
  && ok "display extras restored live (aspect=$orig_aspect_mode widescreen=$orig_wide_num)" \
  || bad "display extras not restored (last: $(grep '\[menu-live\]' "$LOG" | tail -1))"
now_aspect=$(ini_get aspect_ratio)
[ "$now_aspect" = "$orig_aspect" ] && ok "config.ini aspect_ratio back to $orig_aspect" \
  || bad "config.ini aspect_ratio is '$now_aspect'"

# --- HD texture loading, live (Textures tab) --------------------------
orig_hires=$(ini_get hires_textures)
[ -n "$orig_hires" ] || orig_hires=false
if [ "$orig_hires" = "true" ]; then alt_hires=0; alt_hires_name=false; orig_hires_num=1
else alt_hires=1; alt_hires_name=true; orig_hires_num=0; fi

cmd tex-open "command=hotkey" "keysym=$F1"
sleep 2
wait_state paused 5 >/dev/null
click_item tab Textures textures-tab || true
sleep 0.5
mark
click_item widget hires hires-checkbox || true
sleep 0.5
if apply_line '\[menu\] textures applied: ' | grep -q "hires=$alt_hires "; then
  ok "HD texture toggle went through the live apply path"
else
  bad "HD texture toggle has no live apply (last: $(apply_line '\[menu\] textures applied: '))"
fi
now_hires=$(ini_get hires_textures)
[ "$now_hires" = "$alt_hires_name" ] && ok "config.ini persisted hires_textures=$alt_hires_name" \
  || bad "config.ini says hires_textures='$now_hires'"
mark
click_item widget hires hires-back || true
sleep 0.4
cmd tex-close "command=hotkey" "keysym=$ESC"
sleep 1
wait_state running 5 >/dev/null
for _ in $(seq 1 40); do
  grep_since "hires=$orig_hires_num " && break
  sleep 0.25
done
grep_since "hires=$orig_hires_num " \
  && ok "running core reports hires=$orig_hires_num (restored)" \
  || bad "core never reported hires=$orig_hires_num"

# --- cheats, live (Cheats tab) ----------------------------------------
# A Gecko code is more than a memory poke: it needs Dolphin's code handler
# installed inside the guest, and this build runs statically recompiled code, so
# "did it actually run?" is a real question rather than a formality. The shipped
# 16:9 code writes its first instruction to 0x80003500, so the assertion reads
# that address back out of guest memory instead of trusting a log line.
#
# Start from "no codes on": the per-game ini is created by the test and put back
# by restore_files, and the master switch is forced off so the enable half of
# the test always runs.
mkdir -p "$DATA/GameSettings"
rm -f "$DATA/GameSettings/GBSP8P.ini"
if grep -qE "^[[:space:]]*enable_cheats[[:space:]]*=" "$DATA/config.ini"; then
  sed -i -E 's|^[[:space:]]*enable_cheats[[:space:]]*=.*|enable_cheats = false|' "$DATA/config.ini"
else
  printf 'enable_cheats = false\n' >>"$DATA/config.ini"
fi
CHEAT_READ=/tmp/mgmenu-ui-cheat.bin
rm -f "$CHEAT_READ"
read_guest() { # read_guest <address> <size> <file>
  # Delete the target first. The poll below waits for a non-empty file, so a
  # file left behind by the previous read satisfied it immediately and every
  # caller after the first silently re-read the *old* bytes -- which is how a
  # working Gecko code made the Action Replay assertion "fail" with the Gecko
  # code's own data.
  rm -f "$3"
  cmd "read-guest-$1" "command=read_memory" "address=$1" "size=$2" "path=$3"
  for _ in $(seq 1 60); do
    [ -s "$3" ] && return 0
    sleep 0.1
  done
  return 1
}

cmd cheats-open "command=hotkey" "keysym=$F1"
sleep 2
wait_state paused 5 >/dev/null
click_item tab Cheats cheats-tab || true
sleep 0.5
wait_rect widget enable-cheats 3 >/dev/null \
  && ok "Cheats tab drew its master switch" \
  || bad "Cheats tab has no master switch"
mark
click_item widget enable-cheats cheats-master || true
sleep 0.5
if apply_line '\[menu\] cheats applied: ' | grep -q "enabled=1 "; then
  ok "cheat master switch went through the live apply path"
else
  bad "cheat master switch has no live apply (last: $(apply_line '\[menu\] cheats applied: '))"
fi
now_cheats=$(ini_get enable_cheats)
[ "$now_cheats" = "true" ] && ok "config.ini persisted enable_cheats=true" \
  || bad "config.ini says enable_cheats='$now_cheats'"

if grep -q "\[menu\] cheats: 13 code(s) for GBSP8P" "$LOG"; then
  ok "the shipped code set is listed for the PAL disc (13 codes)"
else
  bad "unexpected code count: $(grep '\[menu\] cheats:' "$LOG" | tail -1)"
fi

# The list is read from an INI whose order nobody should have to memorise, so
# the index of the code under test is taken from the log the menu prints.
gamma_idx=$(grep -o 'cheat [0-9]* = Screen Gamma Correction: 1\.7' "$LOG" |
  tail -1 | grep -oE '[0-9]+' | head -1)
if [[ -n $gamma_idx ]]; then
  ok "the Action Replay half of the list is present (gamma code is widget cheat-$gamma_idx)"
else
  bad "the shipped Action Replay codes are not listed at all"
fi

mark
click_item widget cheat-0 cheats-code || true
sleep 0.6
if apply_line '\[menu\] cheats applied: ' | grep -q "gecko=1/1 "; then
  ok "ticking a Gecko code activated it in the core"
else
  bad "ticking the code did not activate it (last: $(apply_line '\[menu\] cheats applied: '))"
fi

# An Action Replay code is a different execution path: it is stored encrypted
# in the INI and has to be decrypted before the code handler can run it. The
# gamma code patches three instructions to `li r3,1`; the first sits at
# 0x80029930 and is read back below.
if [[ -n ${gamma_idx:-} ]]; then
  mark
  click_item widget "cheat-$gamma_idx" cheats-ar || true
  sleep 0.6
  if apply_line '\[menu\] cheats applied: ' | grep -q "ar=1/12 "; then
    ok "ticking an encrypted Action Replay code activated it"
  else
    bad "Action Replay code did not activate (last: $(apply_line '\[menu\] cheats applied: '))"
  fi
fi

cmd cheats-close "command=hotkey" "keysym=$ESC"
sleep 1
wait_state running 5 >/dev/null
sleep 1.5
if read_guest 0x80003500 16 "$CHEAT_READ"; then
  # od prints the guest word 0x3C608017 as 1780603c (byte-swapped).
  words=$(od -An -tx4 -v "$CHEAT_READ" | tr -s ' ' | sed 's/^ //')
  if printf '%s' "$words" | grep -q "1780603c"; then
    ok "the code handler really ran after a live enable ($words)"
  else
    bad "code handler did not run: 0x80003500 = '$words'"
  fi
else
  bad "could not read guest memory at 0x80003500"
fi

if read_guest 0x80029930 4 "$CHEAT_READ"; then
  ar_word=$(od -An -tx4 -v "$CHEAT_READ" | tr -s ' ' | sed 's/^ //;s/ *$//')
  # 38600001 == `li r3,1` (gamma 1.7); 38600000 is the stock `li r3,0`.
  # od -tx4 prints the guest word byte-swapped on this little-endian host --
  # the code-handler assertion above relies on exactly that, expecting
  # 1780603c for the word 0x3C608017. This check had forgotten, so it demanded
  # the un-swapped 38600001 and reported a successful patch as a failure.
  if [ "$ar_word" = "01006038" ]; then
    ok "the decrypted Action Replay code really patched the game (0x80029930 = $ar_word)"
  else
    bad "Action Replay code did not take effect: 0x80029930 = '$ar_word' (want 01006038 = li r3,1)"
  fi
else
  bad "could not read guest memory at 0x80029930"
fi

# Put it back: reopen, untick the code, untick the master switch.
cmd cheats-reopen "command=hotkey" "keysym=$F1"
sleep 2
wait_state paused 5 >/dev/null
click_item tab Cheats cheats-tab2 || true
sleep 0.5
mark
click_item widget cheat-0 cheats-code-off || true
sleep 0.4
if [[ -n ${gamma_idx:-} ]]; then
  click_item widget "cheat-$gamma_idx" cheats-ar-off || true
  sleep 0.4
fi
click_item widget enable-cheats cheats-master-off || true
sleep 0.5
if apply_line '\[menu\] cheats applied: ' | grep -q "gecko=0/1 .*ar=0/12 .*enabled=0 "; then
  ok "codes and master switch are all off again"
else
  bad "cheats not back off (last: $(apply_line '\[menu\] cheats applied: '))"
fi
cmd cheats-close2 "command=hotkey" "keysym=$ESC"
sleep 1
wait_state running 5 >/dev/null

# --- the PAL code set belongs to the PAL disc, and only to it ---------
# GBSP8P.ini is resolved from the running disc id. GBS.ini is loaded for every
# Beach Spikers region, so a code parked there would be offered to NTSC discs at
# PAL addresses. Hiding the disc's own INI must therefore leave nothing to list
# -- if a code ever migrates into the shared file, that is exactly what this
# fails on.
SYS_INI="$(dirname "$RUN")/Sys/GameSettings/GBSP8P.ini"
if [[ -f $SYS_INI ]]; then
  cp -- "$SYS_INI" /tmp/mgmenu-ui-GBSP8P.ini.bak
  rm -f "$DATA/GameSettings/GBSP8P.ini"
  rm -f "$SYS_INI"
  mark
  cmd cheats-scope-open "command=hotkey" "keysym=$F1"
  sleep 2
  wait_state paused 5 >/dev/null
  click_item tab Cheats cheats-scope-tab || true
  sleep 0.5
  # The list is cached per disc id, so ask for a rescan instead of waiting for
  # the tab to notice a file it has already read once.
  mark
  click_item widget rescan-cheats cheats-scope-rescan || true
  sleep 0.5
  if apply_line '\[menu\] cheats: ' | grep -q "0 code(s) for GBSP8P"; then
    ok "with no PAL INI on disk the tab lists nothing (codes are disc-scoped)"
  else
    bad "codes appeared without the disc's INI: $(apply_line '\[menu\] cheats: ')"
  fi
  # The overlay redraws every frame, and the frames between the tab opening and
  # the rescan landing still carry the cached rows -- so grepping for a cheat
  # widget from before the click always found those stale rows and reported a
  # leak that was never drawn. Start the window at the rescan result, then give
  # it a few frames to redraw before asserting emptiness.
  mark
  sleep 0.5
  grep_since " widget=cheat-0 " \
    && bad "a code widget was drawn without the PAL INI" \
    || ok "no code widgets exist without the PAL INI"
  # GBS.ini is shared by every region and must never carry a code.
  if grep -qE '^\$|^[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{5}$' "$(dirname "$RUN")/Sys/GameSettings/GBS.ini"; then
    bad "the region-shared GBS.ini contains cheats (they would follow every region)"
  else
    ok "the region-shared INI is code-free"
  fi
  cmd cheats-scope-close "command=hotkey" "keysym=$ESC"
  sleep 1
  wait_state running 5 >/dev/null
  cp -- /tmp/mgmenu-ui-GBSP8P.ini.bak "$SYS_INI"
  rm -f /tmp/mgmenu-ui-GBSP8P.ini.bak
else
  note "no Sys/GameSettings/GBSP8P.ini next to the runner; skipping the scoping probe"
fi

# --- savestate, screenshot, reset (States tab) ------------------------
# Compressing a state and writing a PNG are both host-side jobs that have to run
# with the core unpaused, so these checks also prove the menu closes itself
# before queueing the action.
state_slot=$(ini_get state_slot)
[ -n "$state_slot" ] || state_slot=1
slot_num=$(printf '%02d' "$state_slot")
mkdir -p "$DATA/StateSaves"
state_written=$(ls "$DATA/StateSaves"/*.s"$slot_num" 2>/dev/null | head -1)
if [ -n "$state_written" ]; then
  cp "$state_written" "$BACKUP/savestate.s$slot_num"
  state_backup="$BACKUP/savestate.s$slot_num"
  state_written=""
  echo "      slot $state_slot already holds a state; backing it up"
fi
shots_before=$(ls "$DATA"/ScreenShots/*/*.png 2>/dev/null | wc -l)

cmd states-open "command=hotkey" "keysym=$F1"
sleep 2
wait_state paused 5 >/dev/null
click_item tab States states-tab || true
sleep 0.5
mark
click_item widget savestate savestate-button || true
sleep 0.5
grep_since "\[menu\] button: Save state (slot $state_slot)" \
  && ok "Save state button queued the slot $state_slot action" \
  || bad "Save state button did not log its action"
if wait_state running 5; then
  ok "savestate closed the menu and resumed the core"
else
  bad "menu stayed open after Save state"
fi
grep_since "\[menu\] state: saving slot $state_slot" \
  && ok "savestate ran on the host thread after resume" \
  || bad "no host-thread savestate after resume"
state_written=""
for _ in $(seq 1 60); do
  state_written=$(ls "$DATA/StateSaves"/*.s"$slot_num" 2>/dev/null | head -1)
  [ -n "$state_written" ] && break
  sleep 0.25
done
[ -n "$state_written" ] && ok "savestate file written (${state_written##*/})" \
  || bad "no savestate file for slot $slot_num under $DATA/StateSaves"
# Dolphin announces the save through its own OSD ("Saving State...", "Saved
# State to ...") and the filter is supposed to swallow that text and re-render
# it as a toast. This is the only deterministic trigger for the filter in the
# harness: without it, a regression that let OSD text through would go unnoticed.
grep_since "\[menu-osd\] message: " \
  && ok "emulator OSD text was intercepted (never drawn in Dolphin's style)" \
  || bad "no [menu-osd] line: the OSD filter did not run on the save messages"

cmd shot-open "command=hotkey" "keysym=$F1"
sleep 2
wait_state paused 5 >/dev/null
click_item tab States states-tab-shot || true
sleep 0.5
mark
click_item widget screenshot screenshot-button || true
sleep 0.5
grep_since "\[menu\] button: Screenshot" && ok "Screenshot button queued" \
  || bad "Screenshot button did not log"
wait_state running 5 >/dev/null
grep_since "\[menu\] state: screenshot requested" \
  && ok "screenshot request reached the host thread" \
  || bad "screenshot never reached the host thread"
shot_written=""
for _ in $(seq 1 60); do
  shots_now=$(ls "$DATA"/ScreenShots/*/*.png 2>/dev/null | wc -l)
  if [ "$shots_now" -gt "$shots_before" ]; then
    shot_written=$(ls -t "$DATA"/ScreenShots/*/*.png | head -1)
    break
  fi
  sleep 0.25
done
[ -n "$shot_written" ] && ok "screenshot PNG written (${shot_written##*/})" \
  || bad "no PNG appeared under $DATA/ScreenShots"

cmd reset-open "command=hotkey" "keysym=$F1"
sleep 2
wait_state paused 5 >/dev/null
click_item tab States states-tab-reset || true
sleep 0.5
mark
click_item widget reset reset-button || true
sleep 0.5
grep_since "\[menu\] button: Reset game" && ok "Reset button queued" \
  || bad "Reset button did not log"
wait_state running 5 >/dev/null
grep_since "\[menu\] state: reset button" \
  && ok "reset reached the host thread" \
  || bad "reset never reached the host thread"

# --- change the port-0 device LIVE (Input tab) -------------------------
orig_pad=$(ini_get controller1)
# A leftover virtual pointer from an earlier test run is not a state worth
# preserving: fall back to the first evdev pad.
case "$orig_pad" in
  *uinput* | *pointer* | *mouce* | "") orig_pad="evdev/0/Gamepad" ;;
esac
# config.ini writes the binding as `evdev/<n>/<name>` or `prefix|evdev/<n>/<name>`
# depending on how it was set, but the combo box lists `<prefix> (<name>)` when
# a prefix is present and the bare name otherwise. Everything downstream -- the
# "already bound is a no-op" guard, and clicking the row that puts port 0 back
# -- compares against that combo label, so it has to be rebuilt in the combo's
# own spelling. Leaving `Keyboard|evdev/0/Cherry ...` unconverted matched no
# row at all, which silently disabled both branches.
case "$orig_pad" in
  *'|'*)
    orig_rest=${orig_pad#*|}
    orig_display="${orig_pad%%|*} (${orig_rest#evdev/[0-9]/})"
    ;;
  *)
    orig_display=${orig_pad#evdev/[0-9]/}
    ;;
esac
echo "      pad0 before: ${orig_pad:-<none>}"
# The `pad0=` log line prints the binding as `evdev/<n>/<name>` with no prefix,
# while config.ini may carry `prefix|evdev/<n>/<name>`. Comparing a log value
# against the raw config value made a successful re-bind look like a mismatch
# ("came back as evdev/0/Cherry ..., expected Keyboard|evdev/0/Cherry ...").
orig_path=${orig_pad#*|}

cmd reopen "command=hotkey" "keysym=$F1"
sleep 2
wait_state paused 5 >/dev/null
click_item tab Input input-tab || true
sleep 0.5
mark
click_item widget port0 port0-combo || true
sleep 0.5

# Preference order: a real keyboard is always present and cannot disturb the
# pad; then anything that is not a virtual pointer leftover.
items_by_y "port0/" | while IFS=$'\t' read -r y name; do
  case "$name" in
    "(none)" | *"(IMU)"*) continue ;;
  esac
  # The already-bound device must be ranked before anything else: config_menu
  # only applies a real change (choice.value != value), so selecting it logs
  # nothing and the assertion below fails. It has to outrank the keyboard
  # preference too -- when the pad is unbound the keyboard IS the bound device,
  # and rank=0 used to win and pick it, which is exactly how this failed.
  if [[ -n $orig_display && $name == *"$orig_display"* ]]; then
    rank=4
  else
    case "$name" in
      "Keyboard ("*) rank=0 ;;
      *uinput* | *pointer* | *mouce* | *cubic* | *RustDesk*) rank=3 ;;
      *) rank=2 ;;
    esac
  fi
  printf '%s\t%s\n' "$rank" "$name"
done >/tmp/mgmenu-ui-candidates.txt
sort -t$'\t' -k1,1n -k2,2 /tmp/mgmenu-ui-candidates.txt | cut -f2 >/tmp/mgmenu-ui-order.txt

chosen=""
while IFS= read -r name; do
  [ -z "$name" ] && continue
  if try_hover item "port0/$name"; then
    ok "hover confirmed on port0/$name at $HOVER_X,$HOVER_Y"
    press "$HOVER_X" "$HOVER_Y" port0-item
    chosen=$name
    break
  fi
done </tmp/mgmenu-ui-order.txt

if [ -n "$chosen" ]; then
  ok "selected port 0 device: $chosen"
  sleep 0.5
  if grep_since "\[menu\] controller applied: pad0="; then
    ok "controller config applied live (no restart)"
    pad_after=$(grep_since_text '\[menu\] controller applied: pad0=' | tail -1 | sed 's/.*pad0=//')
    echo "      pad0 after : ${pad_after:-<none>}"
    [ -n "$pad_after" ] && [ "$pad_after" != "$orig_path" ] \
      && ok "port 0 re-bound to a different device" \
      || bad "port 0 unchanged ($pad_after)"
  else
    if [ "$chosen" = "$orig_display" ]; then
      ok "re-selected the already-bound device, correctly a no-op"
    else
      bad "no live controller apply logged"
    fi
  fi
else
  bad "no hoverable port-0 device item"
  dismiss_popup port0-cleanup
fi

# Put port 0 back on the device it had, through the UI, so the live-bind path is
# proven in both directions (and the box is left as it was found).
if [ -n "$chosen" ] && [ "$chosen" != "$orig_display" ] &&
   [ "$(items_by_y "port0/" | cut -f2 | grep -Fxc "$orig_display")" -gt 0 ]; then
  mark
  click_item widget port0 port0-combo-back || true
  sleep 0.5
  restored=""
  for _ in $(seq 1 6); do
    if try_hover item "port0/$orig_display"; then
      press "$HOVER_X" "$HOVER_Y" port0-back
      restored=1
      break
    fi
    # The popup scrolls: nudge it and retry if the row is out of view.
    cmd "port0-wheel-$seq" "command=mouse" "x=$HOVER_X" "y=$HOVER_Y" "wheel_y=-3"
    sleep 0.3
  done
  if [ -n "$restored" ] && grep_since "\[menu\] controller applied: pad0="; then
    pad_back=$(grep_since_text '\[menu\] controller applied: pad0=' | tail -1 | sed 's/.*pad0=//')
    [ "$pad_back" = "$orig_path" ] && ok "port 0 re-bound back to $orig_display" \
      || bad "port 0 came back as '$pad_back', expected '$orig_path'"
  else
    bad "could not re-bind port 0 back to $orig_display"
    dismiss_popup port0-back-cleanup
  fi
fi

# --- restore the base resolution and verify it lands live --------------
click_item tab Display display-tab2 || true
sleep 0.5
click_item widget resolution res2 || true
sleep 0.4
mark
click_item item resolution/$RES_BASE res-back || true
sleep 0.5
grep_since "\[menu\] display applied: scale=$RES_BASE_SCALE" \
  && ok "restore applied through the live path (scale=$RES_BASE_SCALE)" \
  || bad "no live display apply for the restore"
cmd close2 "command=hotkey" "keysym=$ESC"
sleep 1
wait_state running 5 >/dev/null
for _ in $(seq 1 40); do
  grep_since "\[menu-live\] efb_scale=$RES_BASE_SCALE " && break
  sleep 0.25
done
grep_since "\[menu-live\] efb_scale=$RES_BASE_SCALE " \
  && ok "restored $RES_BASE live (efb_scale=$RES_BASE_SCALE)" \
  || bad "did not restore efb_scale=$RES_BASE_SCALE (last: $(grep '\[menu-live\]' "$LOG" | tail -1))"
cfg_back=$(ini_get resolution)
[ "$cfg_back" = "$RES_BASE" ] && ok "config.ini restored to $RES_BASE" || bad "config.ini is '$cfg_back'"

# --- audio backend live change ----------------------------------------
cmd reopen2 "command=hotkey" "keysym=$F1"
sleep 2
wait_state paused 5 >/dev/null
click_item tab Audio audio-tab || true
sleep 0.5
mark
click_item widget audio audio-combo || true
sleep 0.5
audio_before=$(ini_get audio_backend)
items_by_y "audio/" | while IFS=$'\t' read -r y name; do
  [ "$name" = "$audio_before" ] && continue
  printf '%s\n' "$name"
done >/tmp/mgmenu-ui-audio.txt

chosen_audio=""
while IFS= read -r name; do
  [ -z "$name" ] && continue
  if try_hover item "audio/$name"; then
    ok "hover confirmed on audio/$name at $HOVER_X,$HOVER_Y"
    press "$HOVER_X" "$HOVER_Y" audio-item
    chosen_audio=$name
    break
  fi
done </tmp/mgmenu-ui-audio.txt

if [ -n "$chosen_audio" ]; then
  ok "selected audio backend: $chosen_audio"
  sleep 0.4
  grep_since "\[menu\] audio backend applied: " \
    && ok "audio backend swapped live (no restart)" \
    || bad "no live audio apply logged"
else
  bad "no hoverable audio backend item"
  dismiss_popup audio-cleanup
fi
cmd close3 "command=hotkey" "keysym=$ESC"
sleep 1
wait_state running 5 >/dev/null

# --- clean stop ---------------------------------------------------------
cmd stop "command=stop"
for _ in $(seq 1 20); do pgrep -x moderngekko-run >/dev/null || break; sleep 0.5; done
pgrep -x moderngekko-run >/dev/null && bad "clean shutdown" || ok "clean shutdown"
grep -qiE "segmentation|abort|assertion|terminate called" "$LOG" && bad "no crashes" \
  || ok "no crashes in the log"
zombies=$(ps -eo stat,comm --no-headers | awk '$1 ~ /^Z/ && /moderngekko/' | wc -l)
[ "$zombies" -eq 0 ] && ok "no zombie emulator processes" || bad "$zombies zombies"

# --- NTSC-U: the other disc gets the other code set ---------------------
# The tab asks the *core's* own game ini loaders, so which codes appear is
# decided by the disc id the emulator booted. Booting the US build is the only
# way to prove that branch honestly -- hand-editing an id into the frontend
# would test a string, not the region split. GBSE8P.ini carries 8 plain-hex
# Action Replay codes from Codejunkies plus the 16:9 Gecko code; none of the
# PAL-only names may show up, and the PAL file must not be consulted at all.
US_SO=$(ls -d "$DIR"/build/modules/GBSE8P/*/gGBSE8P_recomp.so 2>/dev/null | head -1)
if [ -n "$US_SO" ] && [ -d "$DIR/extracted/beach-us" ]; then
  main_log=$LOG
  if launch us "$DIR/extracted/beach-us" "$US_SO"; then
    cmd us-open "command=hotkey" "keysym=$F1"
    sleep 2
    if wait_state paused 10; then
      ok "the NTSC-U disc boots and pauses for the menu"
    else
      bad "the NTSC-U disc never reached the paused state (state=$(field state))"
    fi
    click_item tab Cheats us-cheats-tab || true
    sleep 0.6

    us_line=$(grep '\[menu\] cheats: ' "$LOG" | tail -1)
    if printf '%s' "$us_line" | grep -q "for GBSE8P"; then
      ok "the NTSC-U disc resolves its own game ini ($us_line)"
    else
      bad "the NTSC-U disc did not resolve GBSE8P ($us_line)"
    fi
    if printf '%s' "$us_line" | grep -q "9 code(s)"; then
      ok "the NTSC-U set lists 8 Action Replay codes plus the Gecko code (9)"
    else
      bad "unexpected NTSC-U code count: $us_line"
    fi
    if grep -q "cheat [0-9]* = Max world tour points (ar)" "$LOG"; then
      ok "a decrypted NTSC-U Action Replay code is in the list"
    else
      bad "the NTSC-U Action Replay codes are missing"
    fi
    # The PAL file is a different disc's file; not one of its names may leak.
    leaked=""
    for pal_name in "Screen Gamma Correction" "Dark Uniforms" \
                    "Unrestricted Zoom" "Score 15-1"; do
      grep -q "cheat [0-9]* = .*$pal_name" "$LOG" && leaked="$leaked '$pal_name'"
    done
    [ -z "$leaked" ] && ok "no PAL-only codes are offered to the NTSC-U disc" \
      || bad "PAL codes leaked into the NTSC-U list:$leaked"
    grep -q "for GBSP8P" "$LOG" \
      && bad "the NTSC-U run read the PAL game ini" \
      || ok "the NTSC-U run never touches GBSP8P.ini"

    cmd us-stop "command=stop"
    for _ in $(seq 1 20); do pgrep -x moderngekko-run >/dev/null || break; sleep 0.5; done
    pgrep -x moderngekko-run >/dev/null && bad "NTSC-U instance did not stop" \
      || ok "NTSC-U instance shut down"
    grep -qiE "segmentation|abort|assertion|terminate called" "$LOG" \
      && bad "the NTSC-U build crashed" || ok "no crashes on the NTSC-U disc"
  else
    bad "the NTSC-U instance did not boot"
  fi
  LOG=$main_log
else
  note "no NTSC-U module or extracted disc; skipping the region probe"
fi

# --- the System tab's region switcher ------------------------------------
# The catalogue is derived from the running disc id (its 4th character), so
# this checks three separate things: that discovery resolves a game root AND a
# module for each installed region, that an absent region is a disabled row
# rather than a selection that would boot-fail, and -- the part a screenshot
# could never prove -- that picking another region really reboots onto that
# disc. The restarted process inherits the log fd through execv, so its
# "module loaded" line lands in the same file and names the winning region.
if [ -n "$US_SO" ] && [ -d "$DIR/extracted/beach-us" ]; then
  if launch region "$DIR/extracted/beach" "$SO"; then
    cmd region-open "command=hotkey" "keysym=$F1"
    sleep 2
    if wait_state paused 10; then
      ok "menu opened for the region probe"
    else
      bad "menu did not open for the region probe (state=$(field state))"
    fi
    click_item tab System region-tab || true
    sleep 0.6
    if wait_rect widget region 8 >/dev/null; then
      ok "the System tab offers a region selector"
    else
      bad "no region selector on the System tab"
    fi
    # Straight from the menu's own discovery log: both installed regions must
    # resolve a game root and a module, and the Japanese disc -- which has no
    # extraction on this box -- must read as absent instead of being offered.
    grep -q 'region=GBSP8P .*installed=1' "$LOG" \
      && ok "PAL resolves a game root and a module" \
      || bad "PAL discovery failed (no installed=1 row)"
    grep -q 'region=GBSE8P .*installed=1' "$LOG" \
      && ok "NTSC-U resolves a game root and a module" \
      || bad "NTSC-U discovery failed (no installed=1 row)"
    grep -q 'region=GBSJ8P .*installed=0' "$LOG" \
      && ok "NTSC-J reads as not installed (no disc present)" \
      || bad "NTSC-J did not read as not installed"

    click_item widget region region-combo || true
    sleep 0.6
    for id in GBSP8P GBSE8P GBSJ8P; do
      if wait_rect item "region/$id" 5 >/dev/null; then
        ok "the region list offers $id"
      else
        bad "$id is missing from the region list"
      fi
    done
    # Disabled rows never report hover=1, which is exactly how the missing
    # region stays unclickable.
    if try_hover item "region/GBSJ8P"; then
      bad "the missing NTSC-J disc is selectable"
      dismiss_popup region-j
    else
      ok "the missing NTSC-J disc is a disabled row"
    fi

    click_item item "region/GBSE8P" region-switch || true
    sleep 3
    grep -q 'region switch requested: GBSP8P -> GBSE8P' "$LOG" \
      && ok "picking NTSC-U requests the region switch" \
      || bad "no region switch was requested"
    for _ in $(seq 1 40); do
      grep -q 'module loaded: .*gGBSE8P_recomp.so' "$LOG" && break
      sleep 1
    done
    grep -q 'module loaded: .*gGBSE8P_recomp.so' "$LOG" \
      && ok "the switch rebooted onto the NTSC-U module" \
      || bad "no NTSC-U module load after the region switch"

    cmd region-stop "command=stop"
    for _ in $(seq 1 20); do pgrep -x moderngekko-run >/dev/null || break; sleep 0.5; done
    pgrep -x moderngekko-run >/dev/null && bad "region instance did not stop" \
      || ok "region instance shut down"
    grep -qiE "segmentation|abort|assertion|terminate called" "$LOG" \
      && bad "the region switch crashed" || ok "no crashes across the region switch"
    LOG=${main_log:-$LOG}
  else
    bad "the PAL instance did not boot for the region probe"
  fi
else
  note "no NTSC-U module or extracted disc; skipping the region switch probe"
fi

# --- leave the box as it was found --------------------------------------
restore_files
# From here on the files are final: drop the trap so it cannot undo the repair
# below when the script exits.
trap - EXIT
sed -i "s|^controller1=.*|controller1=$orig_pad|" "$DATA/config.ini" 2>/dev/null || true
sed -i "s|^Device = .*|Device = $orig_pad|" "$DATA/Config/GCPadNew.ini" 2>/dev/null || true
now_pad=$(ini_get controller1)
[ "$now_pad" = "$orig_pad" ] && ok "config.ini pad binding restored ($orig_pad)" \
  || bad "config.ini pad binding is '$now_pad'"
now_res=$(ini_get resolution)
[ "$now_res" = "$res_original" ] \
  && ok "config.ini resolution restored to $res_original" \
  || bad "resolution is '$now_res', expected '$res_original'"
# restore_files puts back the config.ini captured before the pin, so this also
# proves enable_cheats=false (set only to make the master-switch click a
# deterministic transition) never leaked into the player's own settings.
now_cheats=$(ini_get enable_cheats)
[ "$now_cheats" = "${cheats_original:-}" ] \
  && ok "config.ini enable_cheats restored to '${cheats_original:-unset}'" \
  || bad "enable_cheats is '$now_cheats', expected '${cheats_original:-unset}'"

echo "=== $pass passed, $fail failed ==="
echo "  log: $LOG"
[ "$fail" -eq 0 ]
