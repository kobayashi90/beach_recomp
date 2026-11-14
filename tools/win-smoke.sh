#!/bin/bash
# win-smoke.sh -- does the Windows package actually load its module and boot?
#
# The Windows build has failed in ways a successful compile cannot catch: the
# package compiled, the module linked, and the game still did not start because
# the DLL wanted a mingw runtime the zip did not carry, or because nothing in the
# package was ever *run*. This runs the packaged Windows binaries under Wine
# against an extracted game and a module, and fails loudly with the loader's
# complaint instead of a partial screenshot.
#
# Usage:
#   tools/win-smoke.sh <BeachSpikers-Windows.zip> [region]
#
# Requirements: wine, an extracted game at extracted/beach[-us|-jp] (the same
# trees the Linux harnesses use), and the module the package itself produced
# (pass MODULE=<path> to a g<id>_recomp.dll to test that exact file).
set -u

ZIP=${1:?usage: tools/win-smoke.sh <BeachSpikers-Windows.zip> [region]}
REGION=${2:-GBSP8P}
DIR=/home/lain/opencode/beach_recomp
# Wine >= 11 refuses to create its configuration directory under a
# world-writable directory owned by someone else ("'/var/tmp' is not owned by
# you"), so the prefix and work dir must live where the user owns the parent.
WORK=${WORK:-${XDG_CACHE_HOME:-$HOME/.cache}/win-smoke}
WINEPREFIX=${WINEPREFIX:-${XDG_CACHE_HOME:-$HOME/.cache}/win-smoke-prefix}

case "$REGION" in
  GBSP8P) GAME=${GAME:-$DIR/extracted/beach} ;;
  GBSE8P) GAME=${GAME:-$DIR/extracted/beach-us} ;;
  GBSJ8P) GAME=${GAME:-$DIR/extracted/beach-jp} ;;
  *) echo "unknown region $REGION" >&2; exit 2 ;;
esac

die() { echo "FAIL: $*" >&2; exit 1; }
note() { echo "  $*"; }

[ -f "$ZIP" ] || die "no such zip: $ZIP"
[ -d "$GAME" ] || die "no extracted game at $GAME"

command -v wine >/dev/null || die "wine is not installed"

rm -rf "$WORK"
mkdir -p "$WORK"
note "extracting $ZIP"
unzip -q "$ZIP" -d "$WORK" || die "the zip is truncated or not a zip"
pkg=$(find "$WORK" -maxdepth 2 -name 'moderngekko-run.exe' -printf '%h\n' | head -1)
[ -n "$pkg" ] || die "no moderngekko-run.exe in the package"

note "package: $pkg"
for exe in "Beach Spikers.exe" moderngekko-run.exe moderngekko-port.exe dolrecomp.exe; do
  if [ -f "$pkg/$exe" ]; then
    note "  ok   $exe ($(stat -c%s "$pkg/$exe") bytes)"
  else
    note "  MISSING $exe"
  fi
done

# The module is what actually fails to load, so search the package, the user's
# module cache and anything passed in explicitly.
MODULE=${MODULE:-}
if [ -z "$MODULE" ]; then
  MODULE=$(find "$pkg" -maxdepth 2 -name "g${REGION}_recomp.dll" | head -1)
fi
if [ -z "$MODULE" ]; then
  MODULE=$(find /var/tmp "$WORK" -maxdepth 4 -name "g${REGION}_recomp.dll" 2>/dev/null | head -1)
fi
if [ -n "$MODULE" ]; then
  note "module: $MODULE ($(stat -c%s "$MODULE") bytes)"
  # A mingw-built DLL that needs a runtime the package does not ship is the
  # failure this test exists for; list the imports that will not resolve.
  if command -v objdump >/dev/null; then
    imports=$(objdump -p "$MODULE" 2>/dev/null | sed -n 's/^\s*DLL Name: //p' | sort -u)
    missing=""
    for dll in $imports; do
      case "$dll" in
        KERNEL32.dll|USER32.dll|ADVAPI32.dll|WS2_32.dll|SHELL32.dll|GDI32.dll|OLE32.dll|COMDLG32.dll|CRYPT32.dll|msvcrt.dll|ucrtbase.dll|api-ms-win-*|bcrypt.dll|dwmapi.dll|version.dll|winmm.dll|comctl32.dll|setupapi.dll|dbghelp.dll|iphlpapi.dll|dnsapi.dll|netapi32.dll|secur32.dll|userenv.dll|hid.dll|wgldxgi.dll) ;;
        *)
          if ! find "$pkg" -maxdepth 2 -iname "$dll" | grep -q .; then
            missing+=" $dll"
          fi
          ;;
      esac
    done
    if [ -n "$missing" ]; then
      note "  FAIL import(s) not shipped:$missing"
    else
      note "  ok   every non-system import is either shipped or a Windows DLL"
    fi
  fi
else
  note "module: none found (the runner will try to auto-resolve one)"
fi

export WINEPREFIX
export WINEDEBUG=${WINEDEBUG:--all}
note "wine prefix: $WINEPREFIX (first run creates it, give it a minute)"
wineboot -i >/dev/null 2>&1 || die "wineboot failed"

args=(--game "Z:${GAME//\//\\}" --automation-dir "Z:${WORK//\//\\}\\auto" -X11)
[ -n "$MODULE" ] && args+=(--module "Z:${MODULE//\//\\}")
log="$WORK/run.log"
note "running the packaged runner"
( cd "$pkg" && timeout -s KILL 120 wine ./moderngekko-run.exe "${args[@]}" >"$log" 2>&1 )
status=$?

# The pattern needs a word boundary on FAILED: the recomp's own shutdown
# stats line carries "smc_failed=0" (a counter, and zero!), which a bare
# case-insensitive FAILED matches -- that turned a healthy boot into a FAIL.
LOADER_PAT="could not be loaded|couldn't be loaded|not a valid Win32|err:module|is not found|(^|[^_[:alnum:]])FAILED([^_[:alnum:]]|$)"
if grep -qiE "$LOADER_PAT" "$log"; then
  echo "--- loader complaints ---"
  grep -iE "$LOADER_PAT" "$log" | head -10
  die "the package could not load its module"
fi
if [ "$status" -eq 137 ]; then
  note "killed by the timeout, which is the expected shape for a game that booted and kept running"
elif [ "$status" -ne 0 ]; then
  echo "--- last 20 log lines ---"
  tail -20 "$log"
  die "the runner exited with $status"
fi

note "log: $log"
echo "PASS: the Windows package loaded and ran (${REGION})"
