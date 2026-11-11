# Beach Spikers — ModernGekko static recompilation

A static recompilation of **Beach Spikers: Virtua Beach Volleyball** (GameCube) for
Linux, built on:

- [DolRecomp](https://github.com/ExpansionPak/DolRecomp) — static recompiler that turns a GameCube/Wii DOL into portable C or optimized native LLVM objects.
- [ModernGekko](https://github.com/ExpansionPak/ModernGekko) — the runtime the recompiled C links against (built on a Dolphin-derived core for video/audio/HLE).

Both are pulled in as git submodules under `lib/`. Everything is handled through
the top-level `Makefile`. No game data, disc image, or copyrighted asset is
included in this repository — bring your own legally-owned dump (see
[Recompile and Run](#recompile-and-run)).

> [!NOTE]
> This is an **AI-assisted recompilation**: the recompilation pipeline, runtime
> integration, F1 settings menu, performance work (idle-skip, PGO, LTO) and
> packaging were developed with substantial assistance from an AI coding agent.
> The original game code and assets remain the property of their respective
> owners.

## Using This Repository

Clone with submodules and build locally (see [Getting the Source](#getting-the-source)).
Nothing in the `Makefile` or submodule setup needs to change to point it at a
different GameCube/Wii title — pass a different `ISO=` the first time you run
it. The project-specific bits (title, app id, icon) live in the `FRONTEND_NAME`,
`WINDOW_TITLE` and `APP_ID` variables (see [Variables](#variables)).

## Dependencies

CMake, Ninja, and pkg-config, plus a C11/C++23 toolchain. DolRecomp and ModernGekko both build on macOS, Linux, and Windows; this repo's `Makefile` doesn't do anything platform-specific itself, it just drives the same CMake builds each submodule supports natively. `TOOLCHAIN` (see below) follows the compiler used to build ModernGekko.

### Linux

Ubuntu/Debian, matching what `lib/ModernGekko/vendor/dolphin`'s own CI installs for its NoGUI build (`.github/workflows/build.yml`):

```
sudo apt-get install -y ninja-build build-essential pkg-config cmake \
  libevdev-dev libudev-dev libgtk-3-dev libsystemd-dev \
  libbluetooth-dev libasound2-dev libpulse-dev libgl1-mesa-dev \
  libxrandr-dev libxi-dev
```

`build-essential` pulls in GCC, the default toolchain on Linux.

### macOS

Via Homebrew:

```
brew install cmake ninja pkg-config
```

Xcode's command line tools are also required (AppleClang 14.0.3+; verified on AppleClang 17).

### Windows

Visual Studio 2022 (or the standalone Build Tools) with the "Desktop development with C++" workload, for the MSVC toolchain, plus CMake and Ninja on `PATH` (installable via winget/Chocolatey or their own installers). No external package manager is needed beyond that. Dolphin's Windows dependency tree (FFmpeg, SDL, etc.) is vendored as prebuilt binaries/source under `lib/ModernGekko/vendor/dolphin/Externals/`, unlike Linux where system `-dev` packages are expected.

## Getting the Source

```
git clone --recurse-submodules https://github.com/<your-org>/<your-repo>.git
cd <your-repo>
```

If you already cloned without `--recurse-submodules`, `make` will fetch them for you on first run. To do it manually instead:

```
git submodule update --init --recursive
```

Run the build check at any time with:

```
make check
```

It verifies CMake, Ninja, Git, Python, working C11/C++23 compilers, and a
64-bit target with 8-byte pointers. If the source submodules are absent, it
offers to fetch them. Use `make check FETCH=1` for a non-interactive fetch,
or `make check BACKEND=llvm` to validate LLVM 19/20 as well.

> [!NOTE]
> `lib/ModernGekko` vendors a large chunk of Dolphin's dependency tree (SDL, fmt, imgui, Vulkan headers, etc.), so the first submodule sync takes a while and pulls a few hundred MB.

## Recompile and Run

Bring your own legally-owned ISO, no game data is included in or downloaded by this repository. Works with any GameCube or Wii disc; there is no default game, so `ISO=` (or an already-extracted `GAME=`) is required. Point `ISO` at a dump and run:

```
make run ISO=/path/to/Your\ Game.iso
```

This builds DolRecomp and ModernGekko, extracts the ISO, recompiles `main.dol` to C, compiles the result into a native module, and launches the game in a window.

For the optimized LLVM backend:

```
make llvm-run ISO=/path/to/Your\ Game.iso
```

`make llvm` builds the module without launching it. DolRecomp emits native
objects, and RecompCore's module template discovers the generated object
manifest and links every object into the game module automatically. LLVM is
only needed while building; the resulting game module has no LLVM runtime
dependency.

Each game gets its own directory under `extracted/<slug>/`, where `<slug>` is derived from the ISO's filename, so multiple games coexist without clobbering each other. `ISO` is only needed the first time per game, once extracted, run it again by slug instead:

```
make run ISO=iso/Your\ Game.iso        # first time for a new game
make run GAME=Your-Game-Slug           # afterwards
```

Drop ISOs under `iso/` at the repo root (gitignored) for a stable local path.

To just build the tools without touching a game, or to produce the compiled module without launching it:

```
make tools
make recompile ISO=/path/to/game.iso
```

`moderngekko-port` caches compiled modules by DOL hash and toolchain identity, so re-running `recompile`/`run` after the first build is cheap, it hits cache instead of recompiling.

> [!NOTE]
> Wii ISOs need [Wiimms ISO Tools](https://wit.wiimm.de/) (`wit`) for extraction, `make` downloads it automatically into `extern/wit` on first use. GameCube extraction is built into DolRecomp directly and doesn't need this.

## Makefile Targets

Run `make help` (or just `make`, the default target) for this list:

| Target       | Description                                                |
|--------------|--------------------------------------------------------------|
| `check`      | Validate build tools, compilers, architecture, and sources  |
| `tools`      | Build DolRecomp and ModernGekko                             |
| `extract`    | Extract a GameCube/Wii ISO into `extracted/<slug>/`         |
| `recompile`  | Recompile + compile a runnable module                       |
| `run`        | Recompile (if needed) and launch the game                   |
| `llvm`       | Build an optimized LLVM object module                       |
| `llvm-run`   | Build an LLVM object module and launch the game             |
| `appimage`   | Package the build as a single-file AppImage                 |
| `clean`      | Remove all build output                                     |

## Variables

| Variable           | Default                                    | Description                                              |
|--------------------|--------------------------------------------|----------------------------------------------------------|
| `ISO`              | *(none)*                                   | Path to a game ISO. Required the first time per game, also determines that game's slug. |
| `GAME`             | *(none)*                                   | Select an already-extracted game by slug instead of `ISO=`. Required if `ISO` isn't given. |
| `JOBS`             | detected CPU count                         | Parallel build jobs passed to CMake/Ninja.                |
| `CMAKE_BUILD_TYPE` | `Release`                                  | Passed to both submodule builds.                          |
| `BUILD_TESTING`    | `OFF`                                      | Build developer test targets alongside production tools. |
| `BACKEND`          | `c`                                        | Generated-code backend: `c` or `llvm`.                    |
| `LLVM_DIR`         | *(CMake discovery)*                        | Optional path to LLVM 19/20's CMake package.              |
| `RUN_ARGS`         | *(empty)*                                  | Extra flags forwarded to `moderngekko-run` via `make run`, e.g. `--headless`, `--graphics Vulkan`. |
| `TOOLCHAIN`        | `auto`                                      | Compiler for the per-game module: `auto`, `clang`, `gcc`, or `msvc`. See "Toolchain" below. |
| `FRONTEND_NAME`    | `Beach Spikers`                             | Product name shown on the launcher and used as the launcher's filename. |
| `WINDOW_TITLE`     | `Beach Spikers`                             | Fixed game window title. Without it the title is the disc's own name. |
| `APP_ID`           | `io.github.beachspikers`       | Reverse-DNS id for Wayland's app_id (taskbar grouping). |
| `VERSION`          | `1.0.0`                                    | Version stamped into the AppImage file name. |

For example, to force a debug build with extra runner flags:

```
CMAKE_BUILD_TYPE=Debug make run ISO=/path/to/game.iso RUN_ARGS="--headless"
```

## LLVM Backend

DolRecomp supports LLVM 19 and 20. If it is installed outside CMake's normal
search path, point the template at its package directory:

```
make llvm GAME=Your-Game-Slug LLVM_DIR=/usr/lib/llvm-19/lib/cmake/llvm
make llvm-run GAME=Your-Game-Slug LLVM_DIR=/usr/lib/llvm-19/lib/cmake/llvm
```

The portable C backend remains the default and is always available:

```
make recompile GAME=Your-Game-Slug BACKEND=c
```

## Toolchain

The default `TOOLCHAIN=auto` follows the compiler used to build `moderngekko-port`.
This keeps an MSVC build on MSVC and an MSYS2/MinGW build on GCC or Clang instead
of assuming that Visual Studio's `cl` is available.

Override it either way with `TOOLCHAIN=`:

```
make run ISO=/path/to/game.iso TOOLCHAIN=clang   # try clang on Linux anyway
make run ISO=/path/to/game.iso TOOLCHAIN=auto    # let moderngekko-port pick
```

Module builds are cached by DOL hash *and* toolchain identity, so switching `TOOLCHAIN` between runs produces a separate cache entry rather than clobbering a previous build.

## Controller Input

Bindings come from `Config/GCPadNew.ini` / `Config/WiimoteNew.ini` in ModernGekko's user directory (`~/.local/share/moderngekko/Config/` by default). Without one, pad input silently does nothing. You can write one by hand (Dolphin's ini format and key names are stable and documented by the project itself) or let the F1 menu's Input tab pick a device for each port, which generates the ini for you.

## In-game Settings Menu (F1)

F1 opens an overlay menu; ESC closes it. Emulation pauses while it is open, and
the settings that can be applied without a restart land on the next emulated
frame.

| Tab        | Settings                                                                 |
|------------|--------------------------------------------------------------------------|
| Display    | Internal resolution, graphics backend (restart), fullscreen, vsync, aspect ratio, widescreen hack, FPS counters |
| Input      | Device per GameCube port, keyboard-as-pad bindings                        |
| Audio      | Backend (live swap), volume, mute                                         |
| Textures   | HD texture packs on/off, decoded-texture caching, pack folder scan        |
| States     | Savestate slot + save/load, console reset, screenshot                     |
| Cheats     | Master switch, Gecko / Action Replay list for the current disc, rescan    |
| System     | Game/disc info, GameCube system language (restart), save/restart/quit     |

Everything is persisted to `config.ini` in the user directory and applied at
boot by `moderngekko-run`, so the menu is a frontend for that file rather than a
second source of truth. Two settings need a restart on purpose: the graphics
backend (the window and device are created once) and the system language
(EXI_DeviceIPL writes it into the emulated SRAM during boot, before any menu can
open).

Screenshots land in `ScreenShots/<game id>/`, savestates in `StateSaves/`.

### Cheats

The Cheats tab lists the Gecko and Action Replay codes for the disc that is
running. `Enable cheats` is the master switch (Dolphin's `MAIN_ENABLE_CHEATS`);
ticking an individual code turns it on inside the emulated game.

Codes are not stored in `config.ini`. They live in Dolphin's own per-game file,
`GameSettings/<disc ID>.ini` (e.g. `~/.local/share/moderngekko/GameSettings/GBSP8P.ini`),
and the tab reads exactly the same file the core reads at boot, so there is one
source of truth instead of two copies that can drift. Ticking a code writes only
the enabled/disabled list back; codes that ship with the emulator (the 16:9
widescreen code in `Sys/GameSettings/GBSP8P.ini`) are not duplicated into the
user file.

A ticked code applies on the next emulated frame and keeps writing its values
every frame. Unticking it stops the writes, but whatever it already changed
stays in memory until the game rewrites it — reset if you want a clean slate.
The tab never touches the code handler directly; it re-installs itself on the
next frame, which is why toggling is safe while the menu holds the core paused.

If a disc has no codes yet, the tab offers **Create codes file**, which writes a
commented skeleton you can paste codes into before hitting **Rescan**. Gecko
codes require `Sys/codehandler.bin` beside the executables — it is part of the
shipped AppImage, and without it the master switch would list codes that can
never run.

Two live-apply paths are worth knowing about because they used to look like
freezes:

* **Audio backend.** Selecting a backend tears down the old sound stream and
  opens a new one on the thread that draws the menu, because the backend is a
  constructor argument of the stream. PulseAudio's worker blocks in
  `pa_mainloop_iterate()` waiting for the server, and with the menu open the
  emulation is paused so nothing is ever written to the sink — the join waited
  for an event that might never arrive (measured at 17 s of frozen UI). The
  stream destructor now wakes that poll, and the swap costs ~40 ms.
* **Quit.** Dolphin's no-GUI platform implements a stop request as a tap on the
  emulated power button: the guest is asked to shut down politely and only a
  second request forces the process down. A paused guest (any guest, with the
  menu open) can never service the tap, so a stop request arms a 3 s watchdog
  that repeats it. Without it, Quit from the menu could do nothing at all once
  the game had installed its own shutdown hook.

#### Region-scoped codes and builds

Codes are scoped to the **disc ID**, not to the title, so each region reads its
own file and nothing else:

| Disc ID | Region | Codes file |
| --- | --- | --- |
| `GBSP8P` | PAL | `Sys/GameSettings/GBSP8P.ini` |
| `GBSE8P` | NTSC-U | `Sys/GameSettings/GBSE8P.ini` |

`GBS.ini` — the prefix shared by *every* Beach Spikers disc — is loaded for all
regions. It may carry shared settings such as the game database's
`FPRF = True`, but it must never contain a code: a code parked there would be
offered to, and applied at the addresses of, the other region too. The harness
asserts both halves of this. The NTSC-U disc lists its own 9 codes (8 plain-hex
Action Replay plus the 16:9 Gecko code), never opens `GBSP8P.ini`, and shows no
PAL-only code names; and with the PAL file removed the tab lists nothing at all.

Building a second region is just a second extraction, because the module is
keyed on the DOL hash rather than on a hardcoded title:

```
make recompile ISO=/path/to/your-us-dump.iso   # -> extracted/<slug>/, gGBSE8P_recomp.so
```

Both INIs must ship in the AppImage. Packaging used to whitelist only
`GBS.ini` and `GBSP8P.ini`, which produced an image where the NTSC-U disc
showed an empty Cheats tab.

## First Run

With no game configured, `moderngekko-run` starts the launcher instead of
failing, and the launcher asks for an ISO, RVZ or WBFS image. The image is
extracted once into the user directory (`games/<disc ID>/`); after that the game
starts straight from the launcher and the disc image is no longer needed. The
choice is remembered in `default-game.txt` in the user directory.

If that file goes missing (deleted, or the first launch was through
`moderngekko-run --game ...` from a shell, which does not write it), the launcher
finds the existing extraction under `games/` and offers it again instead of asking
for the disc image a second time.

## Prebuilt builds

GitHub Actions builds a toolchain-only package on every push and on releases
(see [`.github/workflows/build.yml`](.github/workflows/build.yml)):

| Platform | Artifact | Trigger |
|----------|----------|---------|
| Linux    | AppImage (single file, no install step) | every push |
| macOS    | tarball of built binary | every push |
| Windows  | zip of binaries + bundled toolchain | `workflow_dispatch` with `windows` = true (experimental) |

The Windows job is manual while it is rebuilt around a **single toolchain
family**. The old package mixed families: an MSVC-built runner/launcher loading a
module compiled by the bundled llvm-mingw clang — two C++ ABIs and two C runtimes
in one process, which compiles fine and then fails at load time. The job now
builds everything with llvm-mingw (static libgcc/libstdc++, no runtime DLLs to
lose) and ships that same compiler for player-side module builds.

A Windows zip is only "done" once `tools/win-smoke.sh <zip>` passes: it extracts
the package, checks every non-system DLL the module imports is either shipped or
a Windows DLL, and boots the game under Wine with the packaged runner.

No artifact is published from that job until it has been checked that way.

These builds contain **no game module and no disc image**. On first run the
launcher asks for your own legally-owned ISO/RVZ/WBFS, extracts it, and offers to
**build the recompiled module** (`g<disc id>_recomp.dll` / `.dylib` / `.so`) from
it: every package ships the builder (`moderngekko-port` + `dolrecomp`), and the
module lands in `<user dir>/StaticRecompModules/`. Building needs a C compiler —
gcc/clang on Linux and macOS — and takes a few minutes; the module is built at
`-O2` with link-time optimisation (and the profile-guided flags when the build
host provides a matching profile). The output goes to
`<user dir>/Logs/module-build.log`.
To ship a build that already contains a region module, build locally with
`make recompile GAME=beach && make appimage`.

A fresh install starts on the settings this build is verified at: Vulkan,
2× EFB (`1280x720`), vsync on, stretched aspect ratio (fills a 16:9 window with
the 4:3 picture) and the frame counter in the window title. Those are the values
in `ConfigResult` / the first-run `config.ini`, so every packaged build — CI
included — starts from them. PAL holds 100 % (50 fps) with them.

## Packaging (AppImage)


`make appimage VERSION=1.0.0` produces `dist/BeachSpikers-1.0.0-x86_64.AppImage`:
one file a player can download, make executable and run, with no install step
and no distribution-specific build.

What the image contains, and why only that:

| Path                          | Contents                                                        |
|-------------------------------|-----------------------------------------------------------------|
| `usr/bin/Beach Spikers`       | the launcher                                                      |
| `usr/bin/beach-spikers`       | symlink, because `Exec=` in a desktop entry cannot contain a space |
| `usr/bin/moderngekko-run`     | the runner (found by the launcher as a sibling)                   |
| `usr/bin/gGBSP8P_recomp.so`   | the PAL recompiled game (also found as a sibling)                 |
| `usr/bin/gGBSE8P_recomp.so`   | the NTSC-U module, when it has been built                        |
| `usr/bin/gGBSJ8P_recomp.so`   | the NTSC-J module, when it has been built                        |
| `usr/bin/Sys/`                | the DSP ROMs, post-processing shaders and the game's own INI      |
| `usr/lib/`                    | 67 shared libraries; the other 12 are left to the host (glibc, X11, Wayland, ALSA, libusb, zlib) |

`Sys/` is resolved relative to the executable, not the working directory, so it
has to sit beside the binaries. The extracted game is deliberately *not* in the
image: it is not ours to redistribute, and the first-run card exists to take the
player's own disc image.

Every region with a built module ships, and that is deliberate: the launcher
resolves a region by looking for `g<disc id>_recomp.so` **beside its own
executable** first, so all three modules in `usr/bin` is exactly what makes the
in-app region switcher offer PAL, NTSC-U and NTSC-J from one download. Set
`REGIONS="GBSP8P"` (or any subset) to build a smaller single-region image; a
region whose module is absent is simply left out of the switcher instead of
failing at boot.

Two details that are easy to get wrong when building one of these:

* `libstdc++.so.6` and `libgcc_s.so.1` are bundled even though the AppImage
  project's excludelist says to skip them. This is a C++ binary built on a
  rolling release; the host's copy can be too old for the symbols it was linked
  against, which fails as `GLIBCXX_3.4.34 not found` on any distribution a year
  behind. Everything else follows the excludelist, so the graphics driver and
  audio stack stay the ones the player's machine is configured for.
* directories are created with `umask 022`. A restrictive umask in the build
  shell otherwise produces root-owned `0700` directories, which makes the image
  unreadable for every user except the one who built it.

`tools/appimage-check.sh` verifies the built file rather than the build tree:
the type-2 header, the assembled contents, the symlink, `desktop-file-validate`,
that every library resolves and that libstdc++ is bundled, that libGL/ALSA/Vulkan
are *not*, and then runs the image offscreen (setup card, OCR'd) and boots the
game headless out of the mounted image.

## Cleaning Up

```
make clean           # everything below
make clean-extracted # extracted disc + compiled modules only, keeps built tools
make clean-tools     # DolRecomp/ModernGekko build trees only
```

## License

DolRecomp and ModernGekko are each distributed under their own upstream licenses (see `lib/DolRecomp/LICENSE` and `lib/ModernGekko/LICENSE`, the latter GPL-3.0-or-later due to its Dolphin-derived runtime). No Nintendo disc image, extracted game data, keys, or copyrighted assets are part of this repository, bring your own legally-owned dump.
