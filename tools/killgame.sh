#!/bin/bash
# killgame.sh -- stop a measurement instance and wait until it is gone.
#
# A plain `pkill -x moderngekko-run; sleep 2` is NOT enough: the emulator takes
# several seconds to tear down Vulkan and the guest session, so the next launch
# silently ran alongside the previous one. Two instances roughly halve the
# reported speed (0.61), three give 0.40 -- which reads exactly like a frame
# rate ceiling and sends you chasing a phantom bottleneck. Always wait for the
# process to actually disappear before starting another run.
#
# OWNERSHIP GUARD
# ---------------
# This script must never touch a session a human is playing. Originally it
# SIGTERMed whatever `moderngekko-run` it found, which meant every measurement
# (cpf.sh, pace.sh, profile.sh, ...) began by killing the live game. That is not
# a crash you can see coming -- it just looks like the game "closed itself".
#
# So: a measurement instance is one whose environment carries MG_HARNESS=1
# (every launcher under tools/ sets it). Anything else is a live play session
# and this script refuses to touch it, exiting non-zero so the calling
# measurement aborts instead of measuring a half-dead process.
set -u

owned() {  # owned PID -- true if that pid was started by a measurement harness
  # /proc/PID/environ is NUL-separated. A variable set to empty would look the
  # same as absent under tr, so match the exact NUL-delimited token.
  tr '\0' '\n' <"/proc/$1/environ" 2>/dev/null | grep -qx 'MG_HARNESS=1'
}

running=$(pgrep -x moderngekko-run 2>/dev/null)
if [ -z "$running" ]; then
  echo "killgame: no instance running"
  exit 0
fi

targets=""
foreign=""
for pid in $running; do
  if owned "$pid"; then
    targets="$targets $pid"
  else
    foreign="$foreign $pid"
  fi
done

if [ -n "$foreign" ]; then
  echo "killgame: REFUSING to stop a live play session (pid$foreign)." >&2
  echo "killgame: quit the game yourself, or measurement must wait." >&2
  exit 1
fi

kill -TERM $targets 2>/dev/null
for _ in $(seq 1 30); do
  pgrep -x moderngekko-run >/dev/null || { echo "killgame: exited cleanly"; exit 0; }
  sleep 1
done

echo "killgame: still alive after 30s, sending SIGKILL"
kill -KILL $targets 2>/dev/null
for _ in $(seq 1 10); do
  pgrep -x moderngekko-run >/dev/null || { echo "killgame: killed"; exit 0; }
  sleep 1
done

echo "killgame: FAILED to stop moderngekko-run" >&2
exit 1
