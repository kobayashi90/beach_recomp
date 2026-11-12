#!/bin/bash
export MG_HARNESS=1  # marks this as a measurement instance; killgame.sh refuses to touch an unmarked one
# pgo.sh -- profile-guided optimisation cycle for the per-game module.
#
# The recompiled module is 64% of CPU-thread time, so it is where the
# remaining gameplay speed lives. It shipped with two things wrong:
#
#   * RECOMPCORE_MODULE_OPT_LEVEL defaulted to 2, and target_compile_options is
#     appended AFTER CMAKE_C_FLAGS_RELEASE, so the template's -O2 quietly
#     overrode Release's -O3. The module has been running at -O2.
#   * CMAKE_C_FLAGS carried -fprofile-use but there were no .gcda at the object
#     paths, so gcc fell back silently -- and -Wno-missing-profile hid it.
#
# Stages:
#   status    show what the module build is actually doing
#   generate  full rebuild with -fprofile-generate (instrumented)
#   train     attract + gameplay runs, each ended with the automation `stop`
#             command so gcov flushes counters at exit (SIGKILL loses them)
#   use       full rebuild with -fprofile-use, after proving profiles resolve
#   restore   put the snapshot .so and the original flags back
#
# The `use` build links with -flto=<n> (default 4; LTO=0 disables). A bare
# -flto serialises its LTRANS jobs and cost ~85 min on this module, while
# -flto=4 finishes in ~13 min with a byte-identical-sized result -- so there is
# no reason to ever build the un-LTO'd variant for anything but a quick probe.
#
# MARCH=native (default) or a portable level (x86-64-v2, x86-64-v3). The
# release modules are built at a baseline so they do not require the exact CPU
# they were profiled on.
#
# Every stage refuses to start while an emulator instance is alive: rewriting
# the .so under a live dlopen() is a lazy-page-fault hazard, and a busy CPU
# makes the training runs unrepresentative.
set -u

DIR=/home/lain/opencode/beach_recomp
# REGION selects which disc's module gets profiled; everything else (game root,
# module name, snapshot directory, training state) derives from it, so PAL and
# NTSC-U never share a snapshot or counters. Override with PGO_GAME / PGO_STATE
# for a region this table does not know.
REGION=${REGION:-GBSP8P}
MODULE_NAME="g${REGION}_recomp.so"
PGO_DIR="$DIR/tools/pgo-state/$REGION"
case "$REGION" in
  GBSP8P) GAME_DIR=${PGO_GAME:-$DIR/extracted/beach} ;;
  GBSE8P) GAME_DIR=${PGO_GAME:-$DIR/extracted/beach-us} ;;
  GBSJ8P) GAME_DIR=${PGO_GAME:-$DIR/extracted/beach-jp} ;;
  *)      GAME_DIR=${PGO_GAME:?set PGO_GAME for unknown region $REGION} ;;
esac
if [ -z "${PGO_STATE:-}" ]; then
  # Savestates are region-specific: a PAL state cannot be loaded by the
  # NTSC-U build (different memory layout), so each region trains on its own.
  case "$REGION" in
    GBSP8P) NFACTS="$DIR/states/gameplay-01.state" ;;
    *)      NFACTS="$DIR/states/gameplay-$REGION.state" ;;
  esac
else
  NFACTS=$PGO_STATE
fi
JOBS=${JOBS:-6}
# -march=native ties the module to the CPU it was built on: the tuned libraries
# carry FMA3/AVX2 code, so a pre-Haswell or Atom-class CPU takes SIGILL the
# moment the module is loaded. MARCH picks the tuning level instead, so a release
# build can target a baseline (x86-64-v2 = SSE4.2/popcnt, v3 = AVX2/BMI/FMA) and
# still be a tuned build. Measure before changing this: MARCH=v3 costs nothing
# measurable here, MARCH=v2 is the widest baseline.
MARCH=${MARCH:-native}
# -mtune takes a microarchitecture, not a level ("x86-64-v3" is rejected), so a
# portable -march pairs with generic tuning unless MTUNE says otherwise.
if [ "$MARCH" = native ]; then
  MTUNE=${MTUNE:-native}
else
  MTUNE=${MTUNE:-generic}
fi

die() { echo "pgo: $*" >&2; exit 1; }

find_build() {
  local b
  b=$(ls -d "$DIR"/build/modules/"$REGION"/*/module-build 2>/dev/null | head -1)
  [ -n "$b" ] || die "no module-build directory for $REGION"
  echo "$b"
}

require_idle() {
  if pgrep -x moderngekko-run >/dev/null; then
    echo "pgo: stopping the running emulator (module/.so must not be live)"
    "$DIR/tools/killgame.sh" >/dev/null || die "could not free the emulator slot"
  fi
}

# set_cache KEY VALUE -- rewrite one CMakeCache entry, creating it if missing.
set_cache() {
  local file=$1 key=$2 value=$3
  python3 - "$file" "$key" "$value" <<'PY'
import sys, re
path, key, value = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path).read()
pattern = re.compile(r'^%s:[A-Z]+=.*$' % re.escape(key), re.M)
line = '%s:STRING=%s' % (key, value)
if pattern.search(text):
    text = pattern.sub(lambda _m: line, text, count=1)
else:
    if not text.endswith('\n'):
        text += '\n'
    text += line + '\n'
open(path, 'w').write(text)
PY
}

cache_flags() {
  local cache=$1
  sed -n 's/^CMAKE_C_FLAGS:STRING=//p' "$cache" | head -1
}

reconfigure_only() {
  local build=$1 label=$2
  local artifact; artifact=$(dirname "$build")
  # Wipe objects and the library so nothing is reused across a flag change.
  find "$build/CMakeFiles" -name '*.o' -delete 2>/dev/null
  rm -f "$artifact/$MODULE_NAME.orig"
  echo "pgo: [$label] reconfiguring"
  cmake -S "$DIR/lib/ModernGekko/vendor/dolphin/module-template" -B "$build" \
    >/dev/null 2>&1 || die "cmake reconfigure failed"
}

build_now() {
  local build=$1 label=$2
  local t0; t0=$(date +%s)
  echo "pgo: [$label] building (log: $PGO_DIR/build-$label.log)"
  if ! ninja -C "$build" -j"$JOBS" >"$PGO_DIR/build-$label.log" 2>&1; then
    tail -25 "$PGO_DIR/build-$label.log" >&2
    die "module build failed"
  fi
  local dt=$(( $(date +%s) - t0 ))
  echo "pgo: [$label] built in $((dt/60))m$((dt%60))s -> $(stat -c%s "$build/$MODULE_NAME") bytes"
}

reconfigure_and_build() {
  reconfigure_only "$1" "$2"
  build_now "$1" "$2"
}

gcda_count() {
  find "$(find_build)" -name '*.gcda' | wc -l
}

# write_manifest <module-build dir>
#
# The module directory's manifest.txt is written by moderngekko-port and
# describes the library *that tool* built. pgo.sh builds with gcc directly, so
# after a tuned build the manifest still claimed "-O2 ... link:no-lto" while the
# library on disk was -O3 + PGO + LTO + -march=native. Anything that reads the
# manifest (identity checks, "is this module tuned?") then concluded the module
# was untuned. This rewrites the lines that describe the build and records the
# PGO facts so the file matches the binary beside it.
write_manifest() {
  local build=$1
  local artifact; artifact=$(dirname "$build")
  local manifest="$artifact/manifest.txt"
  if [ ! -f "$manifest" ]; then
    echo "pgo: no manifest at $manifest (nothing to update)"
    return 0
  fi
  local cflags linker opt compiler_line stage gcda
  cflags=$(sed -n 's/^CMAKE_C_FLAGS:STRING=//p' "$build/CMakeCache.txt" | head -1)
  linker=$(sed -n 's/^CMAKE_SHARED_LINKER_FLAGS:STRING=//p' "$build/CMakeCache.txt" | head -1)
  opt=$(sed -n 's/^RECOMPCORE_MODULE_OPT_LEVEL:STRING=//p' "$build/CMakeCache.txt" | head -1)
  compiler_line=$(gcc --version 2>/dev/null | head -1)
  gcda=$(find "$build" -name '*.gcda' | wc -l)
  case "$cflags" in
    *-fprofile-use*) stage=use ;;
    *-fprofile-generate*) stage=generate ;;
    *) stage=plain ;;
  esac
  python3 - "$manifest" "$opt" "$cflags" "$linker" "$compiler_line" "$stage" "$gcda" "$PGO_DIR" "$REGION" "$MARCH" <<'PY'
import sys
path, opt, cflags, linker, compiler, stage, gcda, pgo_dir, region, march = sys.argv[1:11]
opt = opt or '2'
link = linker.strip() or 'no-lto'
lines = open(path).read().splitlines()
drop = ('flags=', 'compiler=', 'pgo_mode=', 'pgo_toolchain=',
        'pgo_profile_dir=', 'pgo_gcda=', 'pgo_region=', 'pgo_march=',
        'build_stage=')
# Keys are "key=value" at column 0; anything else (a multi-line compiler
# --version banner, stray blank lines) is noise that the old manifest carried.
kept = [line for line in lines
        if not line.startswith(drop) and '=' in line and not line.startswith(' ')]
kept.append('compiler=' + compiler)
kept.append('flags=compile:-O%s %s link:%s' % (opt, cflags.strip(), link))
kept.append('pgo_mode=' + ('use' if stage == 'use' else
                           'generate' if stage == 'generate' else 'off'))
kept.append('pgo_toolchain=gcc+gcov')
kept.append('pgo_region=' + region)
kept.append('pgo_march=' + march)
kept.append('pgo_profile_dir=' + pgo_dir)
kept.append('pgo_gcda=' + str(gcda))
kept.append('build_stage=' + stage)
open(path, 'w').write('\n'.join(kept) + '\n')
PY
  echo "pgo: manifest updated: $manifest"
}

cmd_manifest() {
  write_manifest "$(find_build)"
}

cmd_status() {
  local build; build=$(find_build)
  local artifact; artifact=$(dirname "$build")
  local cache="$build/CMakeCache.txt"
  echo "build:        $build"
  echo ".so:          $(stat -c '%s bytes, %y' "$build/$MODULE_NAME")"
  echo "C_FLAGS:      $(cache_flags "$cache")"
  echo "LINKER_FLAGS: $(sed -n 's/^CMAKE_SHARED_LINKER_FLAGS:STRING=//p' "$cache" | head -1)"
  echo "OPT_LEVEL:    $(sed -n 's/^RECOMPCORE_MODULE_OPT_LEVEL:STRING=//p' "$cache" | head -1)"
  echo "gcda files:   $(gcda_count)"
  local newest
  newest=$(find "$build" -name '*.gcda' -printf '%TY-%Tm-%Td %TH:%TM\n' 2>/dev/null | sort | tail -1)
  [ -n "$newest" ] && echo "newest gcda:  $newest (a -fprofile-use build only counts data older than itself)"
  local snap; snap=$(ls -t "$PGO_DIR"/baseline-*.so 2>/dev/null | head -1)
  [ -n "$snap" ] && echo "snapshot:     $snap"
  echo "running:      $(pgrep -c -x moderngekko-run 2>/dev/null || echo 0) instance(s)"
}

cmd_snapshot() {
  local build; build=$(find_build)
  mkdir -p "$PGO_DIR"
  local snap="$PGO_DIR/baseline-$(date +%Y%m%d-%H%M%S).so"
  cp "$build/$MODULE_NAME" "$snap" || die "snapshot copy failed"
  local cache="$build/CMakeCache.txt"
  {
    echo "snapshot=$snap"
    echo "sha256=$(sha256sum "$snap" | cut -d' ' -f1)"
    echo "c_flags=$(cache_flags "$cache")"
    echo "linker_flags=$(sed -n 's/^CMAKE_SHARED_LINKER_FLAGS:STRING=//p' "$cache" | head -1)"
    echo "opt_level=$(sed -n 's/^RECOMPCORE_MODULE_OPT_LEVEL:STRING=//p' "$cache" | head -1)"
  } >"$PGO_DIR/baseline.txt"
  cat "$PGO_DIR/baseline.txt"
}

cmd_generate() {
  require_idle
  local build; build=$(find_build)
  local cache="$build/CMakeCache.txt"
  mkdir -p "$PGO_DIR"
  cmd_snapshot >/dev/null || die "cannot snapshot the baseline"
  echo "pgo: baseline snapshotted to $(sed -n 's/^snapshot=//p' "$PGO_DIR/baseline.txt")"
  # Old counters are from an abandoned /tmp build tree; they must not survive
  # into the count, and a stale .gcda would be merged into the fresh data.
  find "$build" -name '*.gcda' -delete
  echo "pgo: cleared stale gcda (was $(gcda_count) after delete... expected 0)"
  local gen="-fprofile-generate -fprofile-update=atomic -march=$MARCH -mtune=$MTUNE"
  set_cache "$cache" CMAKE_C_FLAGS "$gen"
  set_cache "$cache" CMAKE_SHARED_LINKER_FLAGS "$gen"
  set_cache "$cache" RECOMPCORE_MODULE_OPT_LEVEL 3
  reconfigure_and_build "$build" generate
  echo "pgo: generate stage done. Now: $0 train"
}

cmd_train() {
  require_idle
  local build; build=$(find_build)
  local artifact; artifact=$(dirname "$build")
  local so="$artifact/$MODULE_NAME"
  # The trainer has to run the *instrumented* module, which lives in
  # module-build/. The artifact path next to it is normally a symlink; if it is
  # a regular file it is a stale copy from an earlier manual `cp`, and the run
  # then trains on the optimised build: zero counters, no error, and a
  # suspiciously healthy `speed=` in the log (the instrumented build cannot run
  # at 1.0). Refuse instead of burning three minutes to learn nothing.
  if [ ! -L "$so" ] || \
     [ "$(readlink -f "$so")" != "$(readlink -f "$build/$MODULE_NAME")" ]; then
    die "artifact $so is not a link to $build/$MODULE_NAME -- fix with:
       ln -sf module-build/$MODULE_NAME '$so'"
  fi
  # Savestates are region-specific, so a region with no state of its own cannot
  # run the gameplay stage -- and silently training on attract only would leave
  # the exact workload we care about unprofiled.
  [ -f "$NFACTS" ] || die "training state missing: $NFACTS"
  mkdir -p "$PGO_DIR"
  local before; before=$(gcda_count)
  echo "pgo: gcda before training: $before"

  # One run per workload. Both end with the automation `stop` command: the
  # runtime takes RequestStop -> Core::Stop, so main returns normally and gcov
  # writes counters at exit. killgame.sh sends signals, which would lose them.
  run_one() {
    local label=$1 seconds=$2; shift 2
    local auto; auto=$(mktemp -d /tmp/mgpgo-XXXXXX)
    mkdir -p "$auto/commands"
    local log="$DIR/logs/pgo-train-$label.log"
    echo "pgo: training '$label' for ${seconds}s"
    cd "$DIR" || die "cd failed"
    # shellcheck disable=SC2086
    setsid nohup ./lib/ModernGekko/build/moderngekko-run \
      --game "$GAME_DIR" --module "$so" --wayland --automation-dir "$auto" \
      "$@" >"$log" 2>&1 </dev/null &
    local i
    for i in $(seq 1 40); do
      [ -f "$auto/status.txt" ] && break
      sleep 1
    done
    [ -f "$auto/status.txt" ] || { echo "pgo: '$label' never booted (see $log)"; return 1; }
    sleep 3
    local f0 f1
    f0=$(sed -n 's/^frame_count=//p' "$auto/status.txt" | head -1)
    # A stray F1 -- physical key, remote-desktop input -- opens the config
    # menu, which pauses the runtime. One gameplay run lost 56 of its 60
    # seconds that way and produced a nearly-empty profile (38 frames instead
    # of ~376) with no error anywhere. The menu is the only thing that pauses
    # a training run, so poll and close it again: the automation loop runs on
    # its own thread and accepts hotkey commands while the core is paused
    # (menu-ui.sh relies on the same fact), and our own log tells us the menu
    # is what paused us -- never fire a blind F1 at some other pause source,
    # that would open the menu instead of closing it.
    local t closes=0 shows hides state
    for t in $(seq 1 "$seconds"); do
      sleep 1
      state=$(sed -n 's/^state=//p' "$auto/status.txt" 2>/dev/null | head -1)
      [ "$state" = "paused" ] || continue
      shows=$(grep -c '\[menu\] Show: visible=1' "$log" 2>/dev/null)
      hides=$(grep -c '\[menu\] Hide: resumed' "$log" 2>/dev/null)
      if [ "${shows:-0}" -gt "${hides:-0}" ]; then
        printf 'command=hotkey\nkeysym=0xFFBE\n' \
          >"$auto/commands/$(printf '090-unpause-%03d.txt' "$t")"
        closes=$((closes + 1))
        echo "pgo: '$label' config menu opened during training -- closed it again"
        sleep 2  # debounce so the next F1 cannot race us into a toggle fight
      fi
    done
    [ "$closes" -gt 0 ] && \
      echo "pgo: '$label' menu closed $closes time(s) during the run"
    f1=$(sed -n 's/^frame_count=//p' "$auto/status.txt" | head -1)
    local sp; sp=$(sed -n 's/^speed=//p' "$auto/status.txt" | head -1)
    printf 'command=stop\n' >"$auto/commands/900-stop.txt"
    for i in $(seq 1 30); do
      pgrep -x moderngekko-run >/dev/null || break
      sleep 1
    done
    if pgrep -x moderngekko-run >/dev/null; then
      echo "pgo: '$label' did not stop cleanly, counters may be lost"
      "$DIR/tools/killgame.sh" >/dev/null
    fi
    echo "pgo: '$label' frames ${f0:-?} -> ${f1:-?}  speed=${sp:-?}"
    rm -rf "$auto"
    return 0
  }

  run_one attract 45 || die "attract training run failed"
  echo "pgo: gcda after attract: $(gcda_count)"
  run_one gameplay 60 --load-state "$NFACTS" || die "gameplay training run failed"
  echo "pgo: gcda after gameplay: $(gcda_count) (baseline was $before)"

  local n; n=$(gcda_count)
  [ "$n" -gt 40 ] || die "too few gcda ($n) -- training did not cover the module"
  tar -czf "$PGO_DIR/gcda-$(date +%Y%m%d-%H%M%S).tar.gz" \
    -C "$build" $(find "$build" -name '*.gcda' -printf '%P ')
  echo "pgo: counters archived in $PGO_DIR. Now: $0 use"
}

cmd_use() {
  require_idle
  local build; build=$(find_build)
  local cache="$build/CMakeCache.txt"
  local n; n=$(gcda_count)
  [ "$n" -gt 40 ] || die "only $n gcda -- run '$0 train' first"
  local use="-fprofile-use -fprofile-partial-training -fprofile-correction -Wno-error=coverage-mismatch -Wno-missing-profile -march=$MARCH -mtune=$MTUNE"
  # LTO=0 turns it off; anything else is the LTRANS job count. This matters
  # for build time, not just speed: a bare -flto serialises LTRANS and spent
  # ~85 min on the 4.7 MB of object code, while -flto=4 does the same work in
  # ~13 min and emits a byte-identical-sized module. It is the shipped config,
  # so build it here rather than leaving it to a manual relink afterwards.
  local jobs=${LTO:-4}
  if [ "$jobs" != "0" ]; then
    use="$use -flto=$jobs"
    set_cache "$cache" CMAKE_SHARED_LINKER_FLAGS "-flto=$jobs"
  else
    set_cache "$cache" CMAKE_SHARED_LINKER_FLAGS " "
  fi
  set_cache "$cache" CMAKE_C_FLAGS "$use"
  set_cache "$cache" RECOMPCORE_MODULE_OPT_LEVEL 3
  reconfigure_only "$build" use

  # Prove the profiles actually resolve at these object paths before spending
  # 40 minutes on a build that would silently ignore them (-Wno-missing-profile
  # is exactly what hid this the first time).
  local probe
  probe=$(cd "$build" && python3 - <<'PY'
import subprocess, re
out = subprocess.run(['ninja','-t','commands'], capture_output=True, text=True).stdout
for line in out.splitlines():
    if 'chunks/' in line and '/usr/bin/gcc' in line:
        line = line.replace('-Wno-missing-profile', '')
        line += ' -Wmissing-profile -Wcoverage-mismatch 2>&1'
        r = subprocess.run(['bash','-c',line], capture_output=True, text=True)
        print(r.stdout.strip()[:600] or 'CLEAN')
        break
PY
)
  case "$probe" in
    CLEAN) echo "pgo: probe chunk used the profile data (no missing-profile warning)" ;;
    *) echo "pgo: PROFILE PROBE FAILED -- refusing to build"; echo "$probe" >&2; exit 1 ;;
  esac
  build_now "$build" use
  write_manifest "$build"
  echo "pgo: use stage done. Measure with: ./tools/speed.sh pgo 40 --load-state $NFACTS"
}

cmd_restore() {
  require_idle
  local build; build=$(find_build)
  local snap; snap=$(sed -n 's/^snapshot=//p' "$PGO_DIR/baseline.txt")
  [ -f "$snap" ] || die "no snapshot recorded"
  cp "$snap" "$build/$MODULE_NAME"
  local cache="$build/CMakeCache.txt"
  set_cache "$cache" CMAKE_C_FLAGS "$(sed -n 's/^c_flags=//p' "$PGO_DIR/baseline.txt")"
  set_cache "$cache" CMAKE_SHARED_LINKER_FLAGS "$(sed -n 's/^linker_flags=//p' "$PGO_DIR/baseline.txt")"
  set_cache "$cache" RECOMPCORE_MODULE_OPT_LEVEL "$(sed -n 's/^opt_level=//p' "$PGO_DIR/baseline.txt")"
  write_manifest "$build"
  echo "pgo: restored $snap"
  cmd_status
}

case "${1:-status}" in
  status)   cmd_status ;;
  snapshot) cmd_snapshot ;;
  generate) cmd_generate ;;
  train)    cmd_train ;;
  use)      cmd_use ;;
  restore)  cmd_restore ;;
  manifest) cmd_manifest ;;
  *) echo "usage: $0 {status|snapshot|generate|train|use|restore|manifest}" >&2; exit 2 ;;
esac
