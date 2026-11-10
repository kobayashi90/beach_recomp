#!/bin/bash
set -euo pipefail
# build-appimage.sh -- package this build as a single-file AppImage.
#
# What goes in, and why only that:
#
#   usr/bin/Beach Spikers        the launcher (the window a player sees first)
#   usr/bin/beach-spikers        symlink, because Exec= cannot contain a space
#   usr/bin/moderngekko-run      the emulator; the launcher finds it as a sibling
#   usr/bin/g<disc id>_recomp.so  the recompiled game, one per region (PAL,
#                                NTSC-U, NTSC-J); the launcher finds them as
#                                siblings, which is what lets the region
#                                switcher offer the other discs
#   usr/bin/Sys/                 Dolphin reads Sys/ relative to the executable
#                                (LINUX_LOCAL_DEV is on in this build), and the
#                                DSP ROMs, post-processing shaders and the
#                                game's own INI live there
#   usr/lib/                     every shared library ldd reports, minus the
#                                ones every desktop already has
#
# The extracted game itself is deliberately absent: it is three hundred
# megabytes, it is not ours to redistribute, and the first-run card exists to
# take the player's own disc image instead.
#
# Usage: packaging/build-appimage.sh [--keep-appdir]
#   VERSION=1.0.0            version in the file name
#   APPIMAGETOOL=/path       use a specific appimagetool
#   REGIONS="GBSP8P GBSE8P GBSJ8P"  which region modules to include (default:
#                            every region that has a built module)
#   STRIP_BUNDLED_LIBS=0     keep debug info in the bundled libraries (bigger)

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
BUILD=$ROOT/lib/ModernGekko/build
APPDIR=$ROOT/build/appimage/AppDir
DIST=$ROOT/dist
TOOLS=$ROOT/build/tools

# Directories inside the image are created by this script, so their mode is
# whatever the umask says. A restrictive umask here produced 0700 directories
# owned by root, which makes the AppImage unreadable for every user except the
# one who built it.
umask 022

VERSION=${VERSION:-1.0.0}
ARCH=x86_64
OUTPUT=$DIST/BeachSpikers-$VERSION-$ARCH.AppImage
STRIP_BUNDLED_LIBS=${STRIP_BUNDLED_LIBS:-1}

say() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# --- inputs -----------------------------------------------------------------

LAUNCHER="$BUILD/Beach Spikers"
RUNNER=$BUILD/moderngekko-run

# Every region that has a built module ships. The launcher resolves a region by
# looking for g<disc id>_recomp.so *beside its own executable* first, so putting
# all three in usr/bin is exactly what makes the in-app region switcher work
# inside the image -- one download, whichever disc the player owns. Set REGIONS
# to a subset (e.g. REGIONS=GBSP8P) to build a smaller single-region image.
REGIONS=${REGIONS:-GBSP8P GBSE8P GBSJ8P}
declare -A MODULE_FOR=()
for id in $REGIONS; do
  path=$(cat "$ROOT/build/modules/$id/active-module.txt" 2>/dev/null || true)
  [[ -f $path ]] || path=$(ls -1 "$ROOT"/build/modules/"$id"/*/g"$id"_recomp.so 2>/dev/null | head -1 || true)
  if [[ -n $path && -f $path ]]; then
    MODULE_FOR[$id]=$path
  else
    say "note: no module for $id, leaving it out"
  fi
done
if [[ ${#MODULE_FOR[@]} -eq 0 ]]; then
  say "note: no game module found; building a toolchain-only image (the launcher"
  say "      will ask for a disc image on first run)"
fi

[[ -x "$LAUNCHER" ]] || die "no launcher at '$LAUNCHER' (run: make tools)"
[[ -x "$RUNNER" ]] || die "no runner at $RUNNER (run: make tools)"

# --- tools ------------------------------------------------------------------

find_appimagetool() {
  if [[ -n ${APPIMAGETOOL:-} ]]; then
    [[ -x $APPIMAGETOOL ]] || die "APPIMAGETOOL=$APPIMAGETOOL is not executable"
    printf '%s\n' "$APPIMAGETOOL"
    return
  fi
  local candidate
  for candidate in "$TOOLS/appimagetool" /tmp/opencode/squashfs-root/usr/bin/appimagetool; do
    if [[ -x $candidate ]]; then printf '%s\n' "$candidate"; return; fi
  done
  if command -v appimagetool >/dev/null 2>&1; then
    command -v appimagetool
    return
  fi
  # Nothing usable: fetch the continuous build once. It is a self-extracting
  # AppImage, so it is used through --appimage-extract and never needs FUSE.
  command -v curl >/dev/null 2>&1 || die "no appimagetool and no curl to fetch one"
  say "fetching appimagetool (one time)..." >&2
  mkdir -p "$TOOLS"
  curl -sSL -o "$TOOLS/appimagetool.AppImage" \
    https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage
  chmod +x "$TOOLS/appimagetool.AppImage"
  (cd "$TOOLS" && ./appimagetool.AppImage --appimage-extract >/dev/null 2>&1)
  [[ -x "$TOOLS/squashfs-root/usr/bin/appimagetool" ]] || die "appimagetool extraction failed"
  printf '%s\n' "$TOOLS/squashfs-root/usr/bin/appimagetool"
}

APPIMAGETOOL_BIN=$(find_appimagetool)
command -v mksquashfs >/dev/null 2>&1 || \
  die "mksquashfs is missing (appimagetool calls it): sudo pacman -S squashfs-tools"

# --- AppDir -----------------------------------------------------------------

say "assembling $APPDIR"
rm -rf "$APPDIR"
mkdir -p "$APPDIR/usr/bin" "$APPDIR/usr/lib" \
         "$APPDIR/usr/share/applications" \
         "$APPDIR/usr/share/icons/hicolor/256x256/apps"

cp -- "$LAUNCHER" "$APPDIR/usr/bin/Beach Spikers"
cp -- "$RUNNER" "$APPDIR/usr/bin/moderngekko-run"
# The module builder. A toolchain-only image has no game module, and the module
# is generated from the player's own disc, so the tool that does that has to
# travel with it: the launcher offers to build one on first run.
for tool in moderngekko-port dolrecomp; do
  if [[ -x "$BUILD/$tool" ]]; then
    cp -- "$BUILD/$tool" "$APPDIR/usr/bin/$tool"
  fi
done
# Each module keeps the name the runner looks for: g<disc id>_recomp.so, beside
# the launcher, so the region switcher can offer the other discs.
for id in "${!MODULE_FOR[@]}"; do
  cp -- "${MODULE_FOR[$id]}" "$APPDIR/usr/bin/g${id}_recomp.so"
  say "module: $id"
done
# Exec= cannot carry a space, and the launcher's sibling lookup resolves
# /proc/self/exe, so a symlink is enough -- no wrapper script needed.
ln -s "Beach Spikers" "$APPDIR/usr/bin/beach-spikers"
chmod +x "$APPDIR/usr/bin/Beach Spikers" "$APPDIR/usr/bin/moderngekko-run"

cp -- "$ROOT/packaging/AppRun" "$APPDIR/AppRun"
chmod +x "$APPDIR/AppRun"
cp -- "$ROOT/packaging/beach-spikers.desktop" "$APPDIR/beach-spikers.desktop"
cp -- "$ROOT/packaging/beach-spikers.desktop" "$APPDIR/usr/share/applications/"
if [[ -f "$ROOT/assets/beach-spikers.png" ]]; then
  cp -- "$ROOT/assets/beach-spikers.png" "$APPDIR/beach-spikers.png"
  cp -- "$ROOT/assets/beach-spikers.png" \
        "$APPDIR/usr/share/icons/hicolor/256x256/apps/beach-spikers.png"
else
  say "note: no icon asset (assets/beach-spikers.png); generating a placeholder"
  if command -v magick >/dev/null 2>&1; then
    magick -size 256x256 xc:'#1a1a2e' -fill '#e94560' -draw 'circle 128,128 128,40' \
      "$APPDIR/beach-spikers.png" 2>/dev/null || true
  fi
  if [[ -f "$APPDIR/beach-spikers.png" ]]; then
    cp -- "$APPDIR/beach-spikers.png" \
          "$APPDIR/usr/share/icons/hicolor/256x256/apps/beach-spikers.png"
  fi
fi

# Sources the module build needs. moderngekko-port resolves them beside itself
# (share/dolphin), which is what makes a toolchain-only image able to build the
# module from the player's own disc.
SHARE=$APPDIR/usr/share/dolphin
for entry in module-template GXRuntime Source/Core/Core/PowerPC/StaticRecomp; do
  src="$ROOT/lib/ModernGekko/vendor/dolphin/$entry"
  [[ -e "$src" ]] || continue
  mkdir -p "$SHARE/$(dirname "$entry")"
  cp -a "$src" "$SHARE/$entry"
done
mkdir -p "$SHARE/Data/Sys/GameSettings"
for ini in "$ROOT"/lib/ModernGekko/vendor/dolphin/Data/Sys/GameSettings/GBS*.ini; do
  [[ -f "$ini" ]] && cp -- "$ini" "$SHARE/Data/Sys/GameSettings/"
done

# Sys/ must sit beside the executables: FileUtil resolves it from the
# executable's own directory in this build. Only the parts a GameCube game
# reaches are copied -- the Wii title databases alone are 12 MB of text.
for entry in GC Shaders Resources; do
  [[ -d "$BUILD/Sys/$entry" ]] || continue
  mkdir -p "$APPDIR/usr/bin/Sys/$entry"
  cp -a "$BUILD/Sys/$entry/." "$APPDIR/usr/bin/Sys/$entry/"
done
# The game's own INIs, and only those belonging to a GameCube disc id:
#   GBSP8P.ini -- the verified 16:9 Gecko code and the PAL Action Replay set
#   GBSE8P.ini -- the NTSC-U set: 8 plain-hex Codejunkies codes plus the same
#                 16:9 Gecko code. Omitting it shipped an AppImage in which the
#                 US disc listed no cheats at all, because the tab reads the
#                 core's per-disc loader and GBSP8P.ini is never consulted for
#                 a GBSE8P disc.
#   GBSJ8P.ini -- the NTSC-J set: no verified region-specific codes yet, but
#                 the file must ship so the cheat tab opens instead of erroring
#                 on a missing per-disc INI.
#   GBS.ini    -- loaded for *every* Beach Spikers region, carries the game
#                 database's `FPRF = True` core setting. The packaged build ran
#                 with FPRF off while every test ran with it on until this was
#                 shipped, so it belongs in the image; it must never contain a
#                 code, or an NTSC disc would be offered PAL addresses.
if [[ -d "$BUILD/Sys/GameSettings" ]]; then
  mkdir -p "$APPDIR/usr/bin/Sys/GameSettings"
  for ini in GBS.ini GBSP8P.ini GBSE8P.ini GBSJ8P.ini; do
    [[ -f "$BUILD/Sys/GameSettings/$ini" ]] &&
      cp -- "$BUILD/Sys/GameSettings/$ini" "$APPDIR/usr/bin/Sys/GameSettings/"
  done
fi
# The Gecko code handler. It sits in Sys/ itself, not in one of the
# subdirectories the loop above copies, and without it "Enable cheats" fails
# with a missing-file error and injects nothing -- the GameSettings INI would
# then list codes that can never run.
if [[ -f "$BUILD/Sys/codehandler.bin" ]]; then
  mkdir -p "$APPDIR/usr/bin/Sys"
  cp -- "$BUILD/Sys/codehandler.bin" "$APPDIR/usr/bin/Sys/"
fi

# --- libraries --------------------------------------------------------------

# Every soname the binaries (and the game module) actually resolve. The module
# matters: it is loaded with dlopen and its dependencies have to be there too,
# but ldd on the executables does not see them.
say "collecting shared libraries"
mapfile -t needed < <(
  {
    ldd -- "$APPDIR/usr/bin/Beach Spikers"
    ldd -- "$APPDIR/usr/bin/moderngekko-run"
    for id in "${!MODULE_FOR[@]}"; do
      ldd -- "$APPDIR/usr/bin/g${id}_recomp.so"
    done
  } | awk '/=> \// { print $3 } /^\t\/.*\.so/ { print $1 }' | sort -u
)

# Libraries every desktop already has, per the AppImage project's own list.
# Bundling e.g. libGL or libasound pins the player to a driver/audio stack
# built into the image instead of the one their machine is configured for.
declare -A excluded=()
EXCLUDELIST=${EXCLUDELIST:-$ROOT/packaging/excludelist}
if [[ -f $EXCLUDELIST ]]; then
  while read -r name; do
    [[ -z $name || $name == \#* ]] && continue
    excluded[$name]=1
  done < <(sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$EXCLUDELIST")
fi

# Exceptions to that list, forced in anyway:
#   libstdc++/libgcc_s -- this is C++ built on a rolling release, so the host's
#   copy can be too old for the symbols the binaries were linked against
#   ("GLIBCXX_3.4.34 not found" on any distribution a year behind). They are
#   ABI-compatible upwards, so shipping the newer one is the safe direction.
declare -A forced=([libstdc++.so.6]=1 [libgcc_s.so.1]=1)

bundled=0
skipped=0
declare -A seen=()
for path in "${needed[@]}"; do
  name=$(basename -- "$path")
  [[ -n ${seen[$name]:-} ]] && continue
  seen[$name]=1
  if [[ -z ${forced[$name]:-} && -n ${excluded[$name]:-} ]]; then
    skipped=$((skipped + 1))
    continue
  fi
  cp -L -- "$path" "$APPDIR/usr/lib/$name"
  bundled=$((bundled + 1))
done
say "bundled $bundled libraries ($skipped left to the host)"

if [[ $STRIP_BUNDLED_LIBS == 1 ]]; then
  say "stripping bundled libraries"
  # Only the copies: this never touches the build tree.
  find "$APPDIR/usr/lib" -name '*.so*' -type f -print0 | xargs -0 -r strip --strip-unneeded 2>/dev/null || true
fi

# A loader for the image itself is never bundled (the runtime provides one), but
# if any dependent pulled in a second copy by accident the image would pick it
# up through LD_LIBRARY_PATH and become unable to start at all.
rm -f "$APPDIR"/usr/lib/ld-linux*.so* "$APPDIR"/usr/lib/ld-*.so* 2>/dev/null || true

# --- build ------------------------------------------------------------------

mkdir -p "$DIST"
rm -f "$OUTPUT" "$OUTPUT.zsync"
say "building $OUTPUT"
# ARCH has to be set explicitly: appimagetool otherwise derives it from the
# host's `uname -m`, which is right here but not on every build machine.
ARCH=$ARCH APPIMAGE_EXTRACT_AND_RUN=1 "$APPIMAGETOOL_BIN" --no-appstream \
  --mksquashfs-opt -noappend "$APPDIR" "$OUTPUT"

[[ -f $OUTPUT ]] || die "appimagetool produced no output"
say "built $OUTPUT ($(du -h -- "$OUTPUT" | cut -f1))"
