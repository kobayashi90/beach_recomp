#!/bin/bash
export MG_HARNESS=1  # marks this as a measurement instance; killgame.sh refuses to touch an unmarked one
# appimage-check.sh -- verifies the packaged AppImage, not the build tree.
#
# Everything here runs against dist/BeachSpikers-*.AppImage, because the whole
# point of packaging is that the result still works when nothing else on this
# machine is available to it. Three kinds of failure are caught:
#
#   * assembly    -- a missing binary, a dangling symlink, a module that is not
#                    where the runner looks for it, a desktop file that no
#                    desktop would accept
#   * linkage     -- a library that was meant to be bundled and is not, so the
#                    image only works on a machine that happens to have it
#   * behaviour   -- the launcher shows the setup card, and the game actually
#                    boots from inside the image
#
# Requires: the AppImage. tesseract/ImageMagick are used when present; the
# checks that need them are reported as skipped, not passed.
set -u

DIR=/home/lain/opencode/beach_recomp
APPIMAGE=${APPIMAGE:-$(ls -1t "$DIR"/dist/BeachSpikers-*.AppImage 2>/dev/null | head -1)}
GAME=${GAME:-$DIR/extracted/beach}
WORK=${WORK:-/tmp/opencode/mg-appimage-check}

pass=0
fail=0
skip=0
ok()   { echo "  PASS: $*"; pass=$((pass + 1)); }
bad()  { echo "  FAIL: $*"; fail=$((fail + 1)); }
note() { echo "  SKIP: $*"; skip=$((skip + 1)); }

[[ -n $APPIMAGE && -f $APPIMAGE ]] || { echo "FAIL: no AppImage in $DIR/dist (run: make appimage)"; exit 1; }

HAVE_OCR=1
for tool in tesseract magick; do
  command -v "$tool" >/dev/null 2>&1 || HAVE_OCR=0
done

rm -rf "$WORK"
mkdir -p "$WORK"

echo "=== packaged AppImage ==="
echo "image: $APPIMAGE ($(du -h -- "$APPIMAGE" | cut -f1))"
echo "work:  $WORK"

# --- 1. it is a real AppImage, not a renamed binary -------------------------
# The type-2 runtime puts its magic in bytes 8..10 ('AI'), and the payload after
# it is a squashfs. A build that silently produced a bare binary would pass a
# "file exists" check and fail on every user's machine.
if [[ $(dd if="$APPIMAGE" bs=1 skip=8 count=3 2>/dev/null) == "AI"* ]]; then
  ok "has the AppImage type-2 header"
else
  bad "missing the AppImage header (not a type-2 image)"
fi
if [[ -x $APPIMAGE ]]; then ok "is executable"; else bad "is not executable"; fi

# --- 2. assembly ------------------------------------------------------------
echo "  -- contents --"
EXTRACT=$WORK/squashfs-root
mkdir -p "$WORK/extract-root"
(cd "$WORK/extract-root" && "$APPIMAGE" --appimage-extract >/dev/null 2>&1)
# --appimage-extract writes squashfs-root relative to the working directory.
[[ -d $WORK/extract-root/squashfs-root ]] && EXTRACT=$WORK/extract-root/squashfs-root
if [[ -d $EXTRACT/usr ]]; then ok "extracts to an AppDir"; else bad "did not extract"; fi

check_file() { # check_file <relative path> <description> [executable]
  local path=$EXTRACT/$1
  if [[ ! -e $path ]]; then bad "$2 is missing ($1)"; return; fi
  if [[ ${3:-} == exec && ! -x $path ]]; then bad "$2 is not executable ($1)"; return; fi
  ok "$2 is present ($1)"
}

check_file AppRun                    "the AppRun entry point" exec
check_file "usr/bin/Beach Spikers"     "the launcher" exec
check_file usr/bin/moderngekko-run   "the runner" exec
check_file usr/bin/gGBSP8P_recomp.so "the recompiled game"
check_file beach-spikers.desktop     "the desktop entry"
check_file beach-spikers.png         "the icon"

# The desktop entry's Exec cannot contain a space, so the launcher is reached
# through a symlink; if it dangles, every launch from a menu fails.
if [[ -L $EXTRACT/usr/bin/beach-spikers && -x $EXTRACT/usr/bin/beach-spikers ]]; then
  ok "the beach-spikers symlink resolves to the launcher"
else
  bad "the beach-spikers symlink is missing or dangling"
fi

# Sys/ is resolved from the executable's own directory, so it has to be there.
if [[ -f $EXTRACT/usr/bin/Sys/GC/dsp_rom.bin ]]; then
  ok "the GC sysdata (DSP ROM) sits beside the executables"
else
  bad "Sys/GC/dsp_rom.bin is missing -- audio will fail without it"
fi
# Both regions ship their own code file: the runner resolves codes by disc id,
# so an image missing GBSE8P.ini hands an NTSC-U player an empty Cheats tab.
# This used to be a single `note`, which meant (a) GBSE8P.ini was never checked
# at all and (b) losing GBSP8P.ini passed the suite -- a silent hole, since the
# packaging whitelist is exactly the thing that decides which of these land in
# the image.
if [[ -f $EXTRACT/usr/bin/Sys/GameSettings/GBSP8P.ini ]]; then
  ok "the PAL code INI is included (GBSP8P.ini)"
else
  bad "Sys/GameSettings/GBSP8P.ini is missing -- the PAL Cheats tab would be empty"
fi
if [[ -f $EXTRACT/usr/bin/Sys/GameSettings/GBSE8P.ini ]]; then
  ok "the NTSC-U code INI is included (GBSE8P.ini)"
else
  bad "Sys/GameSettings/GBSE8P.ini is missing -- an NTSC-U disc would show no cheats"
fi
if [[ -f $EXTRACT/usr/bin/Sys/GameSettings/GBS.ini ]]; then
  ok "the region-shared INI is included (GBS.ini)"
else
  note "no GBS.ini (the shared FPRF core setting will not apply)"
fi
# The code handler is what actually runs a Gecko code. It lives directly in
# Sys/, so the "which sysdata directories" list is easy to miss -- and when it
# is missing, "Enable cheats" only logs an error and injects nothing.
if [[ -f $EXTRACT/usr/bin/Sys/codehandler.bin ]]; then
  ok "the Gecko code handler is included (cheats can actually run)"
else
  bad "Sys/codehandler.bin is missing -- the Cheats tab would list codes that never run"
fi

# A game must never be shipped inside the image: it is not ours to distribute.
if [[ -d $EXTRACT/usr/bin/Game/sys || -d $EXTRACT/Game/sys ]]; then
  bad "the image contains extracted game data"
else
  ok "contains no game data (the player's own disc image is used)"
fi

# --- 3. the desktop entry ---------------------------------------------------
if command -v desktop-file-validate >/dev/null 2>&1; then
  if desktop-file-validate "$EXTRACT/beach-spikers.desktop" >"$WORK/desktop.txt" 2>&1; then
    ok "the desktop entry validates"
  else
    bad "the desktop entry is invalid: $(tr '\n' ' ' <"$WORK/desktop.txt" | cut -c1-160)"
  fi
else
  note "desktop-file-validate is not installed"
fi
if grep -q '^StartupWMClass=io.github.beachspikers.BeachSpikers$' "$EXTRACT/beach-spikers.desktop"; then
  ok "StartupWMClass matches the window's app id"
else
  bad "StartupWMClass does not match the app id (window will get no icon)"
fi

# --- 4. linkage -------------------------------------------------------------
echo "  -- linkage --"
# Resolved the way AppRun resolves them: bundled directory first.
missing=0
host=0
bundled=0
while read -r line; do
  case $line in
    *"not found"*) missing=$((missing + 1)) ;;
    *"$EXTRACT/usr/lib"*) bundled=$((bundled + 1)) ;;
    *"=> /"*) host=$((host + 1)) ;;
  esac
done < <(LD_LIBRARY_PATH="$EXTRACT/usr/lib" ldd "$EXTRACT/usr/bin/Beach Spikers" 2>&1)

if [[ $missing -eq 0 ]]; then ok "every library the launcher needs resolves"; else bad "$missing libraries do not resolve"; fi
if [[ $bundled -gt 20 ]]; then ok "$bundled libraries come from the image"; else bad "only $bundled libraries are bundled"; fi
echo "       ($host are left to the host: glibc, X11, wayland, alsa, usb)"
# The usual reason an AppImage works on the machine that built it and nowhere
# else: a C++ binary newer than the host's libstdc++.
if [[ -f $EXTRACT/usr/lib/libstdc++.so.6 ]]; then
  ok "libstdc++ is bundled (a rolling-release build would otherwise fail on older distributions)"
else
  bad "libstdc++ is not bundled -- GLIBCXX symbol errors on any distribution a year behind"
fi

# These must come from the host: bundling them pins the player to a driver or
# audio stack baked into the image instead of the one their machine uses.
for lib in libGL.so.1 libasound.so.2 libvulkan.so.1; do
  if [[ -f $EXTRACT/usr/lib/$lib ]]; then
    bad "$lib must not be bundled"
  else
    ok "$lib is left to the host"
  fi
done

# --- 5. the launcher runs from inside the image -----------------------------
echo "  -- behaviour --"
RUN=$WORK/run
mkdir -p "$RUN/data" "$RUN/home"
(
  cd "$WORK" || exit 1
  APPIMAGE_EXTRACT_AND_RUN=1 XDG_DATA_HOME="$RUN/data" HOME="$RUN/home" \
    SDL_VIDEODRIVER=offscreen MODERNGEKKO_LAUNCHER_DEBUG=1 \
    MODERNGEKKO_LAUNCHER_SHOT="$RUN/frame" \
    timeout 25 "$APPIMAGE" >"$RUN/log.txt" 2>&1
)
# timeout(1) stopping the launcher is the expected outcome; it only exits when
# a player closes it.
code=$?
if [[ $code -eq 124 || $code -eq 0 ]]; then ok "the launcher started and stayed up"; else bad "the launcher exited with $code"; fi

if grep -qF "first-run card opened" "$RUN/log.txt"; then
  ok "a new player is shown the setup card"
else
  bad "the setup card did not open for a new player"
fi

if [[ $HAVE_OCR == 1 && -f $RUN/frame-2.bmp ]]; then
  magick "$RUN/frame-2.bmp" -resize 200% -colorspace gray -normalize "$RUN/frame.png" 2>/dev/null
  text=$(tesseract "$RUN/frame.png" - --psm 3 2>/dev/null | tr -d '\n' | tr -s ' ')
  for needle in "Welcome to" "Beach Spikers" "Disc image" "Pick an IS"; do
    if grep -qiF -- "$needle" <<<"$text"; then ok "card shows \"$needle\""
    else bad "card does not show \"$needle\" (OCR: $(cut -c1-140 <<<"$text"))"; fi
  done
elif [[ $HAVE_OCR == 0 ]]; then
  note "card OCR (no tesseract)"
fi

# --- 6. the game boots from inside the image -------------------------------
# The module, the DSP/sysdata and the pipeline cache all have to work with the
# image mounted read-only. Headless keeps it off the desktop.
if [[ -d $GAME ]]; then
  (
    cd "$WORK" || exit 1
    LD_LIBRARY_PATH="$EXTRACT/usr/lib" timeout 25 \
      "$EXTRACT/usr/bin/moderngekko-run" --game "$GAME" --headless >"$WORK/game.txt" 2>&1
  )
  if grep -qF "module loaded:" "$WORK/game.txt"; then
    ok "the game module loads from inside the image"
  else
    bad "the game module did not load"
  fi
  if grep -qE "shutdown: native=[1-9][0-9]{4,}" "$WORK/game.txt"; then
    ok "the game ran ($(sed -n 's/.*shutdown: native=\([0-9]*\).*/\1/p' "$WORK/game.txt" | head -1) native dispatches)"
  else
    bad "the game reported almost no native execution -- it booted but did nothing"
  fi
  if grep -qiE "not found|could not open|failed to load.*\.bin" "$WORK/game.txt"; then
    bad "the game log mentions a missing file: $(grep -iE "not found|could not open|failed to load.*\.bin" "$WORK/game.txt" | head -1)"
  else
    ok "nothing in the game log complains about a missing file"
  fi
else
  note "game boot (no extracted game at $GAME)"
fi

echo "=== $pass passed, $fail failed, $skip skipped ==="
[[ $fail -eq 0 ]] || exit 1
