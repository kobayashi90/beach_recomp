#!/bin/bash
export MG_HARNESS=1
# repro-audio.sh -- does switching the audio backend from the F1 menu freeze the
# emulator?
#
# Found by menu-ui.sh: it selected "(default)" while config.ini said Pulse, the
# "[menu] audio backend applied" line never appeared, status.txt stopped being
# rewritten (frozen at the click's command), and the process ignored `stop`.
# That is the shape of a deadlock inside ApplyAudioBackendLive(), which runs on
# the video thread while the menu is drawing.
set -u

DIR=/home/lain/opencode/beach_recomp
DATA=$HOME/.local/share/moderngekko
RUN=$DIR/lib/ModernGekko/build/moderngekko-run
SO=$(ls -1d "$DIR"/build/modules/GBSP8P/*/gGBSP8P_recomp.so 2>/dev/null | head -1)
WORK=/tmp/opencode/mg-repro-audio
AUTO=$WORK/auto
LOG=$WORK/repro.log
F1=0xFFBE

rm -rf "$WORK"
mkdir -p "$AUTO/commands"
seq=0
cmd() { local name=$1; shift; seq=$((seq + 1)); printf '%s\n' "$@" >"$AUTO/commands/$(printf '%03d' "$seq")-$name.txt"; }
field() { sed -n "s/^$1=//p" "$AUTO/status.txt" 2>/dev/null | head -1; }
rect() { tac "$LOG" 2>/dev/null | grep -F -m1 " $1=$2 " | sed -n 's/.* x=\([-0-9]*\) y=\([-0-9]*\) w=\([-0-9]*\) h=\([-0-9]*\).*/\1 \2 \3 \4/p'; }
click_at() { # click_at <x> <y> <label>
  cmd "$3-move" "command=mouse" "x=$1" "y=$2"
  sleep 0.15
  cmd "$3-down" "command=mouse" "x=$1" "y=$2" "button=0" "down=1"
  sleep 0.25
  cmd "$3-up" "command=mouse" "x=$1" "y=$2" "button=0" "down=0"
  sleep 0.5
}

ORIG_AUDIO=$(sed -n 's/^audio_backend=//p' "$DATA/config.ini" | head -1)
echo "configured backend: '$ORIG_AUDIO'"

"$DIR/tools/killgame.sh" >/dev/null 2>&1
sleep 1
MODERNGEKKO_MENU_DEBUG=1 \
  setsid nohup "$RUN" --game "$DIR"/extracted/beach --module "$SO" --wayland \
  --automation-dir "$AUTO" >"$LOG" 2>&1 </dev/null &
RUNPID=$!
for _ in $(seq 1 30); do [[ -f $AUTO/status.txt ]] && break; sleep 1; done
[[ -f $AUTO/status.txt ]] || { echo "FAIL: never booted"; exit 1; }
sleep 8

cmd open "command=hotkey" "keysym=$F1"
for _ in $(seq 1 60); do [[ $(field state) == paused ]] && break; sleep 0.1; done
sleep 1

pa_streams() {
  # Which audio clients PipeWire/Pulse actually has open. Quoted values, so no
  # guessing at a field index.
  pactl list sink-inputs 2>/dev/null |
    grep -E 'application\.name =|application\.process\.binary =|media\.name =|Dolphin Audio Output' |
    sed 's/^[[:space:]]*/    /'
}
echo "dolphin streams (menu closed):"; pa_streams

read -r tx ty tw th <<<"$(rect tab Audio)"
click_at $((tx + tw / 2)) $((ty + th / 2)) audio-tab
sleep 0.4
read -r cx cy cw ch <<<"$(rect widget audio)"
click_at $((cx + cw / 2)) $((cy + ch / 2)) audio-combo
sleep 0.5

before=$(field processed_commands)
WANT=${WANT:-audio/(default)}
read -r ix iy iw ih <<<"$(rect item "$WANT")"
echo "clicking '$WANT' at $((ix + iw / 2)),$((iy + ih / 2))"
cmd audio-item "command=mouse" "x=$((ix + iw / 2))" "y=$((iy + ih / 2))" "button=0" "down=1"
sleep 0.3
cmd audio-item-up "command=mouse" "x=$((ix + iw / 2))" "y=$((iy + ih / 2))" "button=0" "down=0"

# Healthy: the apply logs and commands keep being consumed. Frozen: nothing
# moves at all, which is what the first observation looked like.
echo "waiting for the apply (up to 60 s):"
t0=$(date +%s%N)
applied=no
for ((i = 0; i < 1200; i++)); do
  if grep -q "audio backend applied" "$LOG"; then applied=yes; break; fi
  sleep 0.05
done
t1=$(date +%s%N)
echo "  applied=$applied after $(( (t1 - t0) / 1000000 )) ms"
grep "audio backend applied" "$LOG" | tail -2
# A live sink input while the emulator is actually running is the real proof
# that the new stream was opened: with the menu open the stream is idle and
# PipeWire drops the sink input, so measuring it there proves nothing.
cmd close "command=hotkey" "keysym=0xFF1B"
for ((i = 0; i < 100; i++)); do [[ $(field state) == running ]] && break; sleep 0.1; done
sleep 2
echo "state after closing the menu: $(field state)"
echo "dolphin streams (running, after swap):"; pa_streams

after=$(field processed_commands)
echo "processed_commands: $before -> $after"
echo "last menu-ui frame: $(grep -o 'f=[0-9]*' "$LOG" | tail -1)"

# Does the process still shut down cleanly after a backend swap? menu-ui.sh
# reported "clean shutdown" failing right after this step, so the two may be
# connected rather than independent flakes.
echo -n "sending stop: "
cmd stop "command=stop"
t2=$(date +%s%N)
stopped=no
for ((i = 0; i < 300; i++)); do
  pgrep -x moderngekko-run >/dev/null || { stopped=yes; break; }
  sleep 0.1
done
t3=$(date +%s%N)
echo "stopped=$stopped after $(( (t3 - t2) / 1000000 )) ms"
[[ $stopped == no ]] && pgrep -x moderngekko-run >/dev/null && {
  pid=$(pgrep -x moderngekko-run | head -1)
  echo "still alive: pid=$pid"
  for t in /proc/"$pid"/task/*; do
    printf '%s %-24s %s\n' "$(basename "$t")" "$(cat "$t"/comm 2>/dev/null)" "$(cat "$t"/wchan 2>/dev/null)"
  done | grep -Ev "futex_wait|nanosleep|poll|select" | head -20
}

echo "=== log tail ==="
tail -6 "$LOG"
"$DIR/tools/killgame.sh" >/dev/null 2>&1
# Put the audio backend back: this probe changes real settings.
sed -i "s|^audio_backend=.*|audio_backend=$ORIG_AUDIO|" "$DATA/config.ini"
echo "restored audio_backend=$ORIG_AUDIO"
