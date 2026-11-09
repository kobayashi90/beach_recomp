#!/usr/bin/bash
export MG_HARNESS=1  # marks this as a measurement instance; killgame.sh refuses to touch an unmarked one
# Intro-flicker A/B: ForceProgressive on/off and gather-batch 32/1, same window.
# Each run dumps only the unique presented pictures (MODERNGEKKO_SWAP_DUMP) and
# tools/flicker_stats.py scores the d(i,i+2)/d(i,i+1) shape.
set -u
cd /home/lain/opencode/beach_recomp || exit 1

run() { # label, extra-env...
  local label="$1"; shift
  local dir="/tmp/flicker-$label"
  rm -rf "$dir"; mkdir -p "$dir"
  ./tools/killgame.sh >/dev/null 2>&1
  sleep 1
  local D
  D=$(mktemp -d /tmp/mgflick-XXXXXX)
  env "$@" \
      MODERNGEKKO_SWAP_DUMP=/dev/null \
      MODERNGEKKO_SWAP_DUMP_FILES="$dir" \
      setsid nohup ./lib/ModernGekko/build/moderngekko-run \
      --game extracted/beach \
      --module "$(ls -d build/modules/GBSP8P/*/gGBSP8P_recomp.so | head -1)" \
      --wayland --automation-dir "$D" >"/tmp/flicker-$label.log" 2>&1 </dev/null &
  for _ in $(seq 1 40); do [ -f "$D/status.txt" ] && break; sleep 1; done
  sleep 52
  ./tools/killgame.sh >/dev/null 2>&1
  sleep 2
  echo "=== $label ==="
  python3 tools/flicker_stats.py "$dir"
  rm -rf "$dir"
}

./tools/cfg.sh progressive=on >/dev/null
run base

./tools/cfg.sh progressive=off >/dev/null
run prog_off

./tools/cfg.sh progressive=on >/dev/null
run batch1 STATICRECOMP_GATHER_BATCH=1
