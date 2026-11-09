#!/bin/bash
export MG_HARNESS=1
# repro-quit.sh -- does "Quit without saving" in the F1 menu actually quit?
#
# menu-ui.sh failed its clean-shutdown check twice, and the automation `stop`
# command goes through the same Runtime::RequestStop() the menu's Quit button
# calls. Platform::UpdateRunningFlag() implements that as the emulated power
# button: the *guest* is asked to shut down, and only a second request forces
# the process down. While the menu is open emulation is paused, so the guest can
# never service the request -- which would make the menu's own Quit button do
# nothing at all.
set -u

DIR=/home/lain/opencode/beach_recomp
RUN=$DIR/lib/ModernGekko/build/moderngekko-run
SO=$(ls -1d "$DIR"/build/modules/GBSP8P/*/gGBSP8P_recomp.so 2>/dev/null | head -1)
WORK=/tmp/opencode/mg-repro-quit
AUTO=$WORK/auto
LOG=$WORK/quit.log
F1=0xFFBE

rm -rf "$WORK"
mkdir -p "$AUTO/commands"
seq=0
cmd() { local name=$1; shift; seq=$((seq + 1)); printf '%s\n' "$@" >"$AUTO/commands/$(printf '%03d' "$seq")-$name.txt"; }
field() { sed -n "s/^$1=//p" "$AUTO/status.txt" 2>/dev/null | head -1; }
rect() { tac "$LOG" 2>/dev/null | grep -F -m1 " $1=$2 " | sed -n 's/.* x=\([-0-9]*\) y=\([-0-9]*\) w=\([-0-9]*\) h=\([-0-9]*\).*/\1 \2 \3 \4/p'; }
click_at() {
  cmd "$3-move" "command=mouse" "x=$1" "y=$2"
  sleep 0.15
  cmd "$3-down" "command=mouse" "x=$1" "y=$2" "button=0" "down=1"
  sleep 0.25
  cmd "$3-up" "command=mouse" "x=$1" "y=$2" "button=0" "down=0"
  sleep 0.5
}

MODE=${MODE:-menu-quit}

"$DIR/tools/killgame.sh" >/dev/null 2>&1
sleep 1
MODERNGEKKO_MENU_DEBUG=1 \
  setsid nohup "$RUN" --game "$DIR"/extracted/beach --module "$SO" --wayland \
  --automation-dir "$AUTO" >"$LOG" 2>&1 </dev/null &
for _ in $(seq 1 30); do [[ -f $AUTO/status.txt ]] && break; sleep 1; done
[[ -f $AUTO/status.txt ]] || { echo "FAIL: never booted"; exit 1; }
sleep 8

if [[ $MODE == menu-stop ]]; then
  # The combination repro-audio.sh actually hit: core paused by the menu, then
  # the automation `stop` command instead of a click on Quit.
  echo "mode: stop command while the menu holds the core paused"
  cmd open "command=hotkey" "keysym=$F1"
  for _ in $(seq 1 60); do [[ $(field state) == paused ]] && break; sleep 0.1; done
  sleep 1
  cmd stop "command=stop"
elif [[ $MODE == running-stop ]]; then
  # Control: the same command with the menu never opened.
  echo "mode: stop while the core is running"
  cmd stop "command=stop"
else
  echo "mode: Quit button inside the open menu"
  cmd open "command=hotkey" "keysym=$F1"
  for _ in $(seq 1 60); do [[ $(field state) == paused ]] && break; sleep 0.1; done
  sleep 1
  read -r tx ty tw th <<<"$(rect tab System)"
  click_at $((tx + tw / 2)) $((ty + th / 2)) sys-tab
  sleep 0.4
  read -r qx qy qw qh <<<"$(rect widget quit)"
  echo "clicking Quit at $((qx + qw / 2)),$((qy + qh / 2))"
  click_at $((qx + qw / 2)) $((qy + qh / 2)) quit
fi

echo -n "waiting for exit (20 s): "
exited=no
for ((i = 0; i < 200; i++)); do
  pgrep -x moderngekko-run >/dev/null || { exited=yes; break; }
  sleep 0.1
done
echo "$exited"
echo "menu lines:"
grep -n "^\[menu\]\|^\[hotkey\]\|PowerButton\|power" "$LOG" | tail -8
echo "state=$(field state) last_command=$(field last_command)"

# A second request is what the base platform uses to force the process down;
# report whether that is all it takes, since that tells us whether the fix is
# "resume first" or "ask twice".
if [[ $exited == no ]]; then
  echo -n "second stop request: "
  cmd stop2 "command=stop"
  for ((i = 0; i < 100; i++)); do
    pgrep -x moderngekko-run >/dev/null || { echo "exited after the second request"; break; }
    sleep 0.1
  done
  pgrep -x moderngekko-run >/dev/null && echo "STILL ALIVE after two requests"
fi

"$DIR/tools/killgame.sh" >/dev/null 2>&1
