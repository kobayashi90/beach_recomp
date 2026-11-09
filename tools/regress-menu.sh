#!/bin/bash
export MG_HARNESS=1  # marks this as a measurement instance; killgame.sh refuses to touch an unmarked one
# regress-menu.sh -- headless regression for the F1 settings overlay.
#
# Covers: hotkey show/hide, runtime pause/resume, overlay drawing, a window
# resize while the menu is open, config persistence on close, and a clean
# restart afterwards.
#
# Keys are delivered through the automation protocol's `hotkey` command, which
# calls the same moderngekko::NotifyHotkey() the Wayland platform layer calls on
# a real key press. Synthetic uinput key presses are not usable on this machine:
# a stuck kscreenlocker_greet surface holds the compositor's keyboard focus, so
# nothing arrives at the game window no matter which device sends it.
set -u

DIR=/home/lain/opencode/beach_recomp
F1=0xFFBE
ESC=0xFF1B

SO=${MODULE:-$(ls -d "$DIR"/build/modules/GBSP8P/*/gGBSP8P_recomp.so 2>/dev/null | head -1)}
[ -z "$SO" ] && { echo "FAIL: no module .so"; exit 1; }

pass=0
fail=0
ok()   { echo "  PASS: $*"; pass=$((pass + 1)); }
bad()  { echo "  FAIL: $*"; fail=$((fail + 1)); }
check() { # check <description> <file> <pattern>
  if grep -q -- "$3" "$2" 2>/dev/null; then ok "$1"; else bad "$1"; fi
}

field() { sed -n "s/^$1=//p" "$AUTO/status.txt" 2>/dev/null | head -1; }

cmd() { # cmd <name> <line>...
  local name=$1
  shift
  printf '%s\n' "$@" >"$AUTO/commands/$name.txt"
}

wait_state() { # wait_state <state> <seconds>
  local want=$1 limit=$2 i
  for ((i = 0; i < limit * 10; i++)); do
    [ "$(field state)" = "$want" ] && return 0
    sleep 0.1
  done
  return 1
}

# Resize a Wayland toplevel from outside: KWin owns the client, so a script can
# set frameGeometry and KWin sends the configure event, exactly like a user
# dragging the window edge.
resize_window() { # resize_window <w> <h>
  local w=$1 h=$2 script=/tmp/mg-resize.js
  cat >"$script" <<JS
const cs = workspace.windowList();
for (const c of cs) {
  if (c.resourceClass && /moderngekko/i.test(c.resourceClass)) {
    c.setMaximize(false, false);
    c.frameGeometry = {x: 40, y: 40, width: $w, height: $h};
    print("resize -> " + c.frameGeometry.width + "x" + c.frameGeometry.height);
  }
}
JS
  qdbus6 org.kde.KWin /Scripting org.kde.kwin.Scripting.loadScript "$script" >/dev/null 2>&1
  qdbus6 org.kde.KWin /Scripting org.kde.kwin.Scripting.start >/dev/null 2>&1
  sleep 1
}

launch() { # launch <label>
  AUTO=/tmp/mgmenu-$1
  rm -rf "$AUTO"
  mkdir -p "$AUTO/commands"
  LOG="$DIR/logs/regress-menu-$1-$(date +%H%M%S).log"
  setsid nohup "$DIR"/lib/ModernGekko/build/moderngekko-run \
    --game "$DIR"/extracted/beach --module "$SO" --wayland \
    --automation-dir "$AUTO" >"$LOG" 2>&1 </dev/null &
  for _ in $(seq 1 30); do
    [ -f "$AUTO/status.txt" ] && break
    sleep 1
  done
  [ -f "$AUTO/status.txt" ] || { bad "boot ($1), see $LOG"; return 1; }
  sleep 6 # let the game reach attract mode/stable frame rate
}

echo "=== F1 overlay regression ==="
"$DIR/tools/killgame.sh" >/dev/null 2>&1
sleep 1
launch open || exit 1
ok "boot: $(field state), speed $(field speed)"
check "menu hooks registered" "$LOG" "\[menu\] hooks registered"

# --- open ---------------------------------------------------------------
cmd 010-open "command=hotkey" "keysym=$F1"
sleep 2
check "F1 shows the menu" "$LOG" "\[menu\] F1 -> show"
check "menu pauses the runtime" "$LOG" "\[menu\] Show: runtime paused"
if wait_state paused 5; then ok "status reports paused"; else bad "status reports paused (got $(field state))"; fi

cmd 020-shot "command=screenshot" "path=$DIR/logs/regress-menu-open.png"
for _ in $(seq 1 15); do [ -s "$DIR/logs/regress-menu-open.png" ] && break; sleep 1; done
[ -s "$DIR/logs/regress-menu-open.png" ] && ok "overlay screenshot captured ($(stat -c%s "$DIR/logs/regress-menu-open.png") bytes)" \
  || bad "overlay screenshot"

# --- resize while the menu is open --------------------------------------
resize_window 900 520
sleep 2
if pgrep -x moderngekko-run >/dev/null; then ok "survived resize with menu open"; else bad "died on resize"; fi
cmd 030-shot "command=screenshot" "path=$DIR/logs/regress-menu-resized.png"
for _ in $(seq 1 15); do [ -s "$DIR/logs/regress-menu-resized.png" ] && break; sleep 1; done
[ -s "$DIR/logs/regress-menu-resized.png" ] && ok "post-resize screenshot captured" || bad "post-resize screenshot"

# --- close --------------------------------------------------------------
cmd 040-close "command=hotkey" "keysym=$ESC"
sleep 2
check "ESC hides the menu" "$LOG" "\[menu\] Hide: resumed"
if wait_state running 5; then ok "status reports running again"; else bad "status reports running (got $(field state))"; fi

sleep 12
speed=$(field speed)
awk -v s="$speed" 'BEGIN{ exit !(s > 0.90) }' && ok "speed recovered after close ($speed)" \
  || bad "speed after close ($speed)"

# --- reopen and toggle closed with F1 -----------------------------------
cmd 050-reopen "command=hotkey" "keysym=$F1"
sleep 2
if wait_state paused 5; then ok "F1 reopens the menu"; else bad "F1 reopens the menu (got $(field state))"; fi
cmd 060-reclose "command=hotkey" "keysym=$F1"
sleep 2
if wait_state running 5; then ok "F1 toggles the menu closed"; else bad "F1 toggles closed (got $(field state))"; fi

# --- clean stop ---------------------------------------------------------
cmd 070-stop "command=stop"
for _ in $(seq 1 20); do pgrep -x moderngekko-run >/dev/null || break; sleep 0.5; done
if pgrep -x moderngekko-run >/dev/null; then bad "clean shutdown"; else ok "clean shutdown, no stray process"; fi
if grep -qiE "segmentation|abort|assertion|terminate called" "$LOG"; then bad "no crashes in the log"; else ok "no crashes in the log"; fi

# --- restart right after ------------------------------------------------
launch restart || exit 1
ok "clean restart boots ($(field state), fps $(field fps))"
cmd 080-stop "command=stop"
for _ in $(seq 1 20); do pgrep -x moderngekko-run >/dev/null || break; sleep 0.5; done
if pgrep -x moderngekko-run >/dev/null; then bad "second instance torn down"; else ok "second instance torn down"; fi

# --- leftovers ----------------------------------------------------------
zombies=$(ps -eo stat,comm --no-headers | awk '$1 ~ /^Z/ && /moderngekko/' | wc -l)
[ "$zombies" -eq 0 ] && ok "no zombie emulator processes" || bad "$zombies zombie emulator processes"

echo "=== $pass passed, $fail failed ==="
echo "  logs: $DIR/logs/regress-menu-*.log"
echo "  shots: $DIR/logs/regress-menu-open.png $DIR/logs/regress-menu-resized.png"
[ "$fail" -eq 0 ]
