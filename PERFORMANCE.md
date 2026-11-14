# Beach Spikers — performance notes

Target: 50 fps (speed = 1.000) on the Intel UHD 630 / i3-10100 box, internal
1280x720. That is set in `~/.local/share/moderngekko/config.ini` as
`[Video] resolution=1280x720` (EFB scale 2); `GFX.ini`'s `InternalResolution` is
written by the frontend from it, so editing that file directly does not survive a
run. See *Current state*.

`speed` is the emulator's own measure of emulated time vs wall clock, read from
the automation `status.txt`. `speed = 1.000` means the 50 Hz game really runs at
50 fps. `fps`/`vps` are present counters and are only meaningful at speed 1.

## Current state (2026-11-06)

| Configuration | Gameplay (`states/gameplay-01.state`) | Attract / opening |
|---|---|---|
| single core, before this work | 0.587 | ~1.0 |
| + locked-L1 identity window | 0.605 | ~1.0 |
| + dual core (`CPUThread = True`) | 0.81 (~40 fps) | ~1.000 (49.45 fps) |
| + module at `-O3` with PGO | 0.994-0.995 (49.7 fps) | 1.000 (49.85 fps) |
| same build, busy box (load 3.5-4.0) | 0.92-0.93 | 1.000 until the 37 s mark |
| + inline gather-pipe stores, plain `-O2` | 0.899 (at load 5.6-7.7!) | — |
| **+ inline gather-pipe stores, `-O3` PGO** | **1.000 (50.00 fps), 2/2 runs** | **mean 0.989, min 0.844, 4/50 s < 0.90** |

Target reached: gameplay is pinned at 1.000 / 50.00 fps (both repeats, box at
load ~1), and the opening's mean went 0.917-0.924 -> 0.989 with the seconds
below 0.90 cut from 13-15 to 4 (see *Inline gather-pipe stores*). The old
"gameplay inside 1 %" is now "gameplay exact"; the opening is no longer the
part that misses.
Remaining headroom is small enough that measurement noise on this box (load
average 1-20 depending on what else is running) is the same size as any further
change, so always read `uptime` next to a `speed=` number.

**Internal resolution is NOT free, and until 2026-11-04 it was never applied.**
Two separate things:

* The setting is owned by the **frontend**, not Dolphin. `config.ini` `[Video]
  resolution=640x528|1280x720|...` is read at boot, mapped to an integer EFB scale
  (`tools/frontend_config.cpp`: `640x528`→1, `1280x720`→2, `1920x1080`→3,
  `2560x1440`→4, ...), and *written into* `Config/GFX.ini` — including on shutdown.
  Editing `GFX.ini`'s `InternalResolution` alone is therefore silently undone by
  the very next run. Observed exactly that: set 2, run, read back 1.
* Because of it, every earlier IR comparison in this file was **two runs of the
  native setting**. With the frontend value actually set, the real cost appears.
  Back-to-back, interleaved, 20 s each on `states/gameplay-01.state`:

  | `config.ini` resolution | speed | fps |
  |---|---|---|
  | `1280x720` (EFB scale 2) | 0.908 / 0.908 | 45.5 |
  | `640x528` (EFB scale 1, native) | 0.933 / 0.927 | 46.5 |

  So 1280x720 costs **~2.5 %** — small, repeatable, and a fair trade for the
  picture. `./tools/cfg.sh res=1280x720` now writes the frontend value (and
  mirrors the scale into `GFX.ini` for anyone reading that file directly).

## Smoothness: the 50 Hz / 60 Hz mismatch (found 2026-11-04)

"Speed = 1.000 and the fps counter reads 50.0" does **not** mean smooth. This is
the PAL release, so the emulated VI runs at 50.00 Hz and produces a frame every
**20.00 ms**. The desktop was running at **2560x1440@59.95**, i.e. a vblank every
**16.68 ms**, and the monitor reports `Vrr: incapable`. A 60 Hz grid cannot show
5 frames evenly in 6 vblanks, so the presentation engine holds one frame out of
every five for a second vblank:

    hold pattern (vblanks per frame): 2, 1, 1, 1, 1, 2, 1, 1, 1, 1, ...
    -> 995 doubled frames per 100 s = ~9.9 visible hitches per second

That is a 10 Hz beat riding on top of the motion. It reads as a perfect frame
rate in every counter and still looks like judder — which is exactly what "the
opening is still not 100% smooth" means.

Measured with `MODERNGEKKO_PACING_DEBUG=1` (present-interval histogram), the
emulator's own pacing was already perfect at **n=402 frames, mean=20.000 ms,
zero frames off cadence** — so nothing on the emulation side needed changing.
Window size is unrelated too (900x492, 1400x792 and 1800x1000 all hold
speed 1.000), and neither is internal resolution (IR 1/2/3 all hold 1.000: the
CPU thread, not the GPU, is the constraint).

**The fix exists but is off by default, because it costs native resolution.**
The monitor advertises 50 Hz only at 1920x1080 and below — its EDID has exactly
three 2560x1440 timings (59.95, 120, 144 Hz) and none at 50 Hz — and KWin offers
no custom-mode support, so matched refresh at native resolution is not reachable
from userspace at all.

It *is* reachable at kernel level, and the EDID says so explicitly. `edid-decode`
on `card1-HDMI-A-1`:

    Display Range Limits: 48-144 Hz V, 30-240 kHz H, max dotclock 600 MHz
    DTD 1: 2560x1440 59.95 Hz  88.787 kHz  241.5 MHz (preferred)

So the panel **accepts anything from 48 Hz up**, and a computed 2560x1440 mode at
50 Hz (~196 MHz, 74 kHz) or at **100 Hz** (~391 MHz, 148 kHz) is far inside every
limit. 100 Hz is the better target: 100/50 is exactly 2, so every guest frame is
held exactly two vblanks — perfect cadence instead of a beat — and it avoids
running the panel at its lowest refresh. Enabling it is one cmdline and one
reboot (`video=HDMI-A-1:2560x1440@100`, see *Matched refresh* below); nothing in
the emulator changes.

`./tools/play.sh` therefore **keeps the native mode by default** (2560x1440@59.95)
and only switches when **`MG_MATCH_REFRESH=1`** is set; when it does switch it
restores the previous mode on exit, including crash or Ctrl-C. At 50 Hz the
vblank period *is* 20.00 ms, so every frame is held exactly one vblank and the
judder disappears — that is the 1080p50 trade-off, and it was rejected in favour
of native resolution.

Practical consequence while native: motion is produced correctly but lands on an
uneven 60 Hz grid. Expect ~9.9 doubled frames/s on top of otherwise perfect
pacing. Nothing emulator-side can remove it; only the display timing can.

**Pacing is not the cause and cannot be tuned away.** On 2026-11-04 the present
mode was forced three ways with the new `MODERNGEKKO_PRESENT_MODE` override
(`fifo`, `mailbox`, `immediate`) and with `ImmediateXFBEnable` both on and off:
every combination reported the same 50 presents/s at `mean=20.00 ms`, and the
37 s intro slowdown was identical (mean 0.919–0.924, 13–15 of 50 seconds below
0.90). The swapchain never held the cadence hostage; the guest frame time does.

Trap hit while writing the launcher: `kscreen-doctor -o` marks the active mode
with `*` and the EDID-preferred mode with `!`, and the mode that is both carries
**both** markers (`1:2560x1440@59.95!*`). A `[*!]?` pattern silently drops it, so
the "current mode" lookup fell through to the next entry and the script restored
the desktop to a 75 Hz mode. The pattern is now `[*!]*`, and the active mode is
selected by its `*` rather than by list position.

## Flicker: the picture is interlaced, and we stitch two fields (found 2026-11-04)

This is a PAL title and the VI runs **480i at 50 Hz**, not progressive. That was
not guessable from config, and release builds compile `DEBUG_LOG_FMT` out, so
`LogField()` printed nothing. `MODERNGEKKO_VI_DEBUG=1` (added in
`Core/HW/VideoInterface.cpp`, one line per second) now reports the real state:

    [vi] field=even addr=016a75a0 WPL=40 STD=80 ACV=264 interlaced_xfb=1
         interlaced_mode=1 force_progressive=1 halflines_even=625 stride=1280
         width=640 height=528

`STD/WPL == 2` and `interlaced_mode=1` are the textbook interlaced signature, and
the game alternates between **two XFB buffers** (`0x016025a0` / `0x016a75a0`), one
per field, with 264 active lines each.

`[Hacks] ForceProgressive` defaults to **true**, so Dolphin reads 528 lines out of
the doubled-stride XFB: each presented frame is the newest field stitched to the
other field, which was captured **20 ms earlier**. Static areas are fine; moving
edges get a half-frame vertical mismatch — the classic comb, which reads as
shimmer/flicker on high-contrast diagonal detail. On a 6th-generation era CRT the
deflicker filter hid this; a 1440p LCD shows it.

The alternative is real and one config flip away, but it is a genuine trade:

| `[Hacks] ForceProgressive` | Output per present | Consequence |
|---|---|---|
| `True` (default) | 640x528, two fields stitched | full vertical detail, combs in motion |
| `False` | 640x264, one field | no comb, **half vertical resolution** |

Verified live with the diagnostic above: with `progressive=off` the same title
reports `height=264 stride=2560 force_progressive=0`. Speed is unaffected either
way (`mean=1.0048` vs `1.0060` on the opening), so this is purely a
picture-quality choice, not a performance one.

`./tools/cfg.sh progressive=on|off` flips it. Which one looks right is a human
judgement — the shim cannot see the screen, and the automation screenshot path
returns a stale XFB in dual-core mode, so burst captures are not frame-accurate
(measured: frames 1–5 of an 8-frame burst were byte-identical). `tools/comb.sh`
exists to score vertical combing when a trustworthy capture path is available;
its automation screenshots are not it.

Note the obvious-in-hindsight point: **`present_count` is not a present counter.**
It increments once in `ViSwap`/`ImmediateSwap` and again inside `Presenter::Present()`,
so `present_count/frame_count == 2.01` is a double *count*, not a double *present*.
`MODERNGEKKO_PACING_DEBUG=1` counted 50 completed presents per second at 50 fps,
which is the number that settles it. An earlier revision of this file blamed
suspected double-presenting for the judder; that was wrong.

## The module was never optimised (found 2026-11-04)

The per-game module is 64 % of CPU-thread time, and it has been running on
default codegen the whole time:

* `CMAKE_C_FLAGS_RELEASE` supplies `-O3`, but `module-template/CMakeLists.txt`
  appends `target_compile_options(-O${RECOMPCORE_MODULE_OPT_LEVEL})` **after**
  the flags, and `RECOMPCORE_MODULE_OPT_LEVEL` defaults to `2`. Last flag wins,
  so every chunk was compiled at **`-O2`**.
* `CMAKE_C_FLAGS` carried `-fprofile-use`, but there were no `.gcda` anywhere
  near the object paths (the only 78 files in the tree belonged to an abandoned
  `/tmp/ModernGekko-Template` build), so gcc silently ignored the flag. The
  `-Wno-missing-profile` in the same flags hid the warning that would have said
  so. Re-running one chunk compile with `-Wmissing-profile` unsuppressed
  printed "Datei für Profilingzählerdaten ... wurde nicht gefunden", i.e. PGO
  was **not** applied to the 0.81 baseline.

Both are fixed by `tools/pgo.sh` (see *Build / rebuild*), which drives a real
generate → train → use cycle and refuses to run the use stage until a probe
compile proves the profiles resolve.

Cycle actually run for the result above:

| Stage | What it does | Time | Artifact |
|---|---|---|---|
| `generate` | `-fprofile-generate` build of all 81 chunks | 26m23s | 91.8 MB instrumented `.so` |
| `train` | attract 45 s + gameplay 60 s, both ended via automation `stop` so gcov flushes | ~2 min | 78/81 chunks covered |
| `use` | `-fprofile-use` + `-O3` build | 18m00s | 52.3 MB `.so` |

The `use` stage is the one that matters twice over: it refuses to start unless a
probe chunk compiles clean with `-Wmissing-profile` **unsuppressed** (proof the
profiles resolve), and it reports **0 coverage-mismatch warnings** (profiles are
matched to the exact object paths, so any change to the module build directory
layout silently invalidates the whole set). Instrumented training runs are very
slow — ~0.19 speed — which is normal and does not affect profile quality.

Keeping the two levers in one cycle means `-O3` and PGO are attributed
together (+~23 % combined). If a single-change attribution is ever needed, it
has to be a separate module cycle, not a guess.

## Inline gather-pipe stores (lever 2, done 2026-11-06)

The last big host-call counter: every display-list store to the write-gather
pipe page went `mem_write*` -> `get_ram_ptr` miss -> `external_write` host call
-> `HookExternalWrite` -> `GPFifoManager::Write32` -> `CheckGatherPipe`. The
Nov 4 play run counted **555,389,494** of them (`mmio_gather`), against 252 M
`ptr_calls` -- the single largest call count in the system, and the slow phase
of the opening was gather-heavy (`GatherPipeBursted` 5.9 % +
`HookExternalWrite` 3.8 % of its samples).

**The fix (CPU ABI v5): the module stages into GPFifo's buffer itself.** Three
tail fields appended byte-identically to both `CPUState` copies
(GXRuntime `core/cpu.h` + `include/moderngekko/cpu_state.h`):

| field | what it is |
|---|---|
| `gather_pipe_base` | GPFifo's staging buffer (`m_gather_pipe`). **NULL disables the path** -- published null while lockstep journaling is on, so the hooks keep owning journaling, exactly like the L1 window. |
| `gather_pipe_cursor` | `u8**` pointing **at** `PPCState.gather_pipe_ptr`, the host's live count -- not a copy. |
| `gather_flush` | host drain (`StaticRecompCore::HookGatherFlush` -> `GPFifoManager::CheckGatherPipe`). |

`gather_pipe_store()` (static inline in the header, so it lands in all 81
chunks) runs before `get_ram_ptr` in `mem_write8/16/32/64`: big-endian bytes
straight into the buffer (same byte order as `FastWrite*`), cursor advanced,
and the host is called only when a 32-byte block has filled -- the
module-side twin of Dolphin's `optimizeGatherPipe`. Non-pipe addresses fall
through with one mask+compare; `base == NULL` reproduces the old hook path
byte for byte.

**Why the cursor is a pointer to the host field, not a mirrored value:** there
is then no publish discipline at all, on either side. Savestate restore, HLE
`host_call`, interpreter fallback, `ResetGatherPipe`, a host `Write32` from
any path -- every reader of the count sees the true value at every instant,
even mid-staging. The only ordering that matters is the flush at >= 32 bytes,
and inside it the host's `memmove` is safe because the module re-reads
`*cursor` on its next store (it never keeps `p` across a flush). Staged bytes
below 32 are invisible to the FIFO exactly as they were on the old path
(UpdateGatherPipe only ships full blocks), so guest-visible FIFO semantics do
not change.

Savestates serialize only the register prefix (ends before `external_read`),
so the tail fields are invisible to state files -- old `.state` files load
unchanged -- and the load-time `cpu_state_size` guard rejects a stale `.so`
with a clear message (both sides were rebuilt together anyway).

**Verification** (all runs on the fast path):

* `mmio_gather` = **555,389,494 -> 0** on every run (smoke + 3 PGO runs);
  `mmio_other` unchanged (~150 k), `ptr_calls` unchanged in character.
* Frame content: 107,886 unique colours in the automation screenshot (the
  Nov 4 reference for real content was ~45 k) -- display lists are intact.
* Clean shutdown, no zero-access spam, no errors, `smc_failed=0`.

**Numbers** (see *Current state* for the table): plain `-O2` + fast path =
0.899 while the box was at load 5.6-7.7 (the old `-O2` baseline was 0.81
idle); full `-O3` PGO cycle 2 (generate 29m40s / train 78-of-81 gcda / use
20m15s, probe clean) = **1.000 (50.00 fps), 2/2 gameplay runs**, and the
opening mean 0.917-0.924 -> **0.989** with 4/50 s below 0.90 (was 13-15) and
min 0.56-0.62 -> 0.844. The slow phase got its first real relief because it
was the gather-heavy phase; what remains is genuine guest CPU work.

## Audio quality is a speed readout, not a separate bug

Dolphin's mixer is silent about drift, so `AudioCommon/Mixer.cpp` counts the two
recovery paths (queue too long → jump the playhead forward; queue empty → fill
or loop) and prints them once a second when `MODERNGEKKO_AUDIO_DEBUG=1`:

    [audio] overruns=0 underruns=1 in=48042 out=48000 target=30 queued=2 (1s)

Measured on a 0.774-speed gameplay run: **~285 underruns/s and 17 overruns in
total**. `GRANULE_SIZE` is 256 samples at 48 kHz (~187 granules/s), so that is
more than one starvation per granule — i.e. the DSP cannot produce 48 kHz worth
of samples because the whole emulator is 22 % slow. The mixer's recovery (jump
the playhead back and loop) is what makes it sound like the music is rushing or
stuttering. No audio setting fixes that; `AudioBufferSize` absorbs jitter, not a
22 % shortfall.

With the PGO module at 0.994 the report reads `in=48042 out=48000 target=30
queued=31` with **~1 underrun/s and <=3 overruns/s**, which is healthy. Attract
mode reports `in=32028` — that is the game's own 32 kHz streaming rate, not a
problem.

**Trap that cost an hour:** the first version of the counters reported a solid
`in=8000 out=48000` and ~267 underruns/s even at speed 0.995, which looks like a
catastrophic audio bug. It was the never-activated Skylander portal mixer: such
FIFOs are mixed on every output block and therefore starve on every call. The
counters now gate on `m_ever_pushed` (set in the inline `PushSample`), so only
FIFOs that have actually carried audio are reported.


## How to measure

    ./tools/speed.sh LABEL SECONDS --load-state "$PWD/states/gameplay-01.state"

* Exactly one instance may run; the script kills strays and refuses to print
  numbers if a second one appeared (two instances report ~0.61, three ~0.40).
* Run at least two repeats; run-to-run spread on this box is about +/-3 %.
* `./tools/intro.sh LABEL SECONDS` samples the automation status file once per
  second **from first boot**, which is the only way to see the opening sequence:
  `speed.sh` warms up past it. It prints a per-second `t speed fps cpu% load
  frames ratio` trace plus mean/min/max and the count of seconds below 0.90.
  Environment: `MG_ENV` (extra assignments, e.g.
  `MODERNGEKKO_PRESENT_MODE=fifo MODERNGEKKO_PACING_DEBUG=1`), `MG_NICE`,
  `MG_ARGS`. The opening is the heaviest content in the game and the only part
  that drops below real time, so it needs its own measurement or it is invisible.
* `./tools/cfg.sh [res=WxH] [vsync=on|off] [immediate=on|off] [progressive=on|off]`
  writes the frontend resolution into `config.ini` (authoritative) and the other
  keys into `GFX.ini`. It also **deletes the key from every other section first**,
  because the loader reads each key from exactly one section and silently ignores
  it anywhere else. `ImmediateXFBEnable` is in `[Hacks]`, not `[Hardware]`:
  writing it to `[Hardware]` was a no-op that produced two "identical" A/B runs
  which were then reported as a real measurement.
* `MODERNGEKKO_VI_DEBUG=1` prints the VI configuration once a second (`[vi]`
  lines): field, XFB address, WPL/STD/ACV, the interlaced flags, stride/width/
  height. This is the only way to read output format on a release build, because
  `DEBUG_LOG_FMT`/`LogField()` are compiled out.
* `./tools/shot.sh` / `./tools/shotseq.sh` capture framebuffer PNGs through the
  automation protocol. In dual-core mode the automation screenshot returns a
  stale XFB, so it cannot be used to judge dual-core rendering — use the window
  itself for that. (A dump of a mostly-white frame is this limitation, not a
  broken render: `shot-dual-nostate.png` predates the PGO work and shows the
  same thing, while the `seq-dual-*` captures have ~45k colours of real content.)
  Measured again 2026-11-04: 5 of 8 screenshots in a 350 ms-apart burst were
  byte-identical, so bursts are not frame-accurate either.
* `THREAD="CPU thread" ./tools/profile.sh LABEL` samples the recompiled module
  and the host. Saved profiles snapshot the binaries (`tools/profsnap.py`) so
  they keep resolving after a rebuild.

## Matched refresh at native resolution (the structural fix)

Everything above is measurement; this is the one change that actually removes the
50/60 beat without giving up 2560x1440. The panel's own range limits allow it
(48-144 Hz, max dotclock 600 MHz), so it only needs to be told the mode exists.

Add to the kernel command line and reboot:

    video=HDMI-A-1:2560x1440@100

100 Hz is chosen over 50 Hz on purpose: 100/50 is exactly 2, so each guest frame
is held exactly two vblanks with no remainder, and the panel is not driven at its
lowest supported refresh. 50 Hz would also work (1:1) if 100 Hz is rejected.

Not yet applied — it requires a reboot, so it is left as a deliberate decision.
After the reboot, confirm the mode actually latched:

    edid-decode /sys/class/drm/card1-HDMI-A-1/edid | grep -i range
    kscreen-doctor -o | grep -E "^*"         # refresh should read 100.00
    ./tools/intro.sh after-100hz 50

Expected: the intro's slow phase (see *Where the time goes*) is still slow — that
is guest CPU, not display — but the ~9.9 doubled frames/s disappear, which is the
part that reads as judder.

## Regression checks (F1 settings overlay)

`./tools/regress-menu.sh` boots the game and drives 18 checks: hook
registration, F1 show, runtime pause, `status.txt` reporting `paused`, overlay
drawing, survival of a window resize while the menu is open, ESC close, resume,
speed recovering, F1 re-open/re-close, clean shutdown, clean restart, and no
stray or zombie processes.

Two things make this runnable without a human at the keyboard:

* The automation protocol has a `hotkey` command
  (`command=hotkey` + `keysym=<X11 keysym>`, F1 = `0xFFBE`, ESC = `0xFF1B`) that
  calls the same `moderngekko::NotifyHotkey()` the Wayland platform layer calls
  on a real key press. Synthetic uinput key presses are unusable on this
  machine: a stuck `kscreenlocker_greet` surface holds the compositor's keyboard
  focus, so no virtual device (nor xdotool) can reach the game window.
* `MODERNGEKKO_IMGUI_DEBUG=1` prints the UI's present rate and vertex volume
  once a second. While the menu is open (core paused) it reads

      [imgui] presents/s=63 vtx=1208..1208

  against

      [imgui] presents/s=50 vtx=0..0

  when closed. That proves the overlay really is redrawn at ~60 Hz from
  `ConfigMenu::ThreadMain` → `Presenter::PresentOverlayFrame` instead of being a
  frozen picture of the frame it was opened on.

Found while building that check: a screenshot request was **silently dropped**
while the menu was open (no file, no error). `ProcessFrameDumping()` only runs
on the emulated-frame path, and it only *stages* the copy — the PNG is written by
`FlushFrameDump()`, which runs off `after_frame_event`, an event only the paused
core would fire. `PresentOverlayFrame()` now does both, so a screenshot of the
paused game lands on disk with the pre-pause frame in it (the frame dumper reads
the XFB texture, so the ImGui overlay itself is never in the dump).

**Trap:** the first version of that called `ProcessFrameDumping()` unguarded and
produced a SIGSEGV in `FrameDumper::IsFrameDumping()` on shutdown — a core dump
that `coredumpctl` only described as "truncated 3.6M", with nothing else to go
on. `ProcessFrameDumping()` dereferences `g_frame_dumper` with no null check,
which is safe on the emulated-frame path (it is only reached while the video
backend is alive) but not here: `g_frame_dumper` is reset during video shutdown,
and the menu thread keeps presenting until `ConfigMenu::Stop()` joins it. The
call is now gated on `g_frame_dumper && g_frame_dumper->IsFrameDumping()` —
verified by killing the game eight times in a row with the menu open and getting
zero new core dumps (9 before, 9 after).

## Where the time goes (dual core, gameplay)

CPU thread is **saturated at ~102 %** of one core; the video/GPU thread uses
~78 %; total ~1.8 cores. Internal resolution makes no difference (IR 0: 0.809,
IR 2: 0.802), so this is not fill-rate bound: the CPU thread is the wall.

Inside the CPU thread: **64 % recompiled module code, 30 % host glue**, 5 %
kernel/other. Host glue is therefore the only large, addressable block; the
module itself is the other 64 % and needs codegen work (PGO), not refactoring.

Measured host costs, as % of *all* samples (both threads, so roughly double when
read as a share of the CPU thread):

| Symbol | % | What it is |
|---|---|---|
| `FifoManager::RunGpuLoop` | 6.8 | GPU thread poll loop |
| `GetHash64_SSE42_CRC32` | 3.9 | texture hashing (whole-texture safe cache) |
| `TextureCacheBase::CopyRenderTargetToTexture` | 1.9 | EFB copies |
| `CommandProcessor::SetCPStatusFromGPU` | 1.8 | per-32-byte FIFO block, GPU thread |
| `StaticRecompCore::Run` | 1.2 | per-burst loop, sync, timing |
| `ResolveNativeAddress` | 1.0 | REL address mapping, per icache invalidation |
| `OnICacheInvalidate` | 1.0 | SMC guard, per icache invalidation |
| `GatherPipeBursted` | 0.7 | per 32-byte gather block |
| `HookExternalPointer` | 0.7 | L1 window misses only (was 149 M calls, now 24 M) |
| `JitCache_TranslateAddress` / `HookInstructionFallback` | 0.6+0.6 | fallback instructions |
| `HookExternalWrite` + `GPFifo::Write32` + `SetCPStatusFromCPU` | 1.3 | gather pipe stores |
| `SyncIn` / `MMU::GetTranslatedAddress` / `TranslateAddress` | 1.4 | per-burst state sync + MMU |

## Where the time goes: fast phase vs slow phase of the opening

Profiled separately with `WARMUP`/`THREAD="CPU thread"` on the same boot, because
the opening is not uniformly heavy. Both phases, share of CPU-thread samples:

| Fast phase (t=20-30 s, speed 0.998) | % | Slow phase (t=36-50 s, speed 0.629) | % |
|---|---|---|---|
| `func_800D95E0` | 10.9 | `func_800FD5E0` | 11.6 |
| `func_800C95E0` | 6.4 | `func_800F95E0` | 8.2 |
| `func_8011D5E0` | 4.8 | `func_800E55E0` | 8.0 |
| `OnICacheInvalidate` | 3.3 | `GatherPipeBursted` | 5.9 |
| `StaticRecompCore::Run` | 2.8 | `HookExternalWrite` | 3.8 |
| `ResolveNativeAddress` | 2.7 | `func_800E95E0` | 3.1 |
| `func_800D55E0` | 2.5 | `StaticRecompCore::Run` | 3.0 |
| `HookInstructionFallback` | 2.0 | `HookExternalPointer` | 2.8 |

The slow phase is **different code**, and it is spread over dozens of chunks with
no single dominant one — so it is genuine guest work (a 3D scene with paired-single
maths: `ppc_psq_load_inline` 3.1 %, `ppc_fma` 2.2 %), not a missed idle loop.

Two consequences worth keeping:

* **There is no cheap idle-skip fix *for this slow phase*.** (Superseded in one
  respect on 2026-11-09: the idle-PC probe itself was made cheap and it was
  worth +0.4 fps — but only for the seven configured spin loops, which are not
  the spinning address here. See *2026-11-09: LTO partitioning, the idle-PC
  probe, and two dead ends*.) The CPU thread really is saturated (94-99 % at 4.1 GHz
  sustained, no thermal throttle), and closing a 0.63 → 1.00 gap would need about
  1.6x the throughput. Micro-optimising one 3-4 % symbol cannot do that.
* **No FMV exists.** The opening is real-time 3D, not a movie: there is no
  `.thp`/`.mth`/`.mo` anywhere under `extracted/beach`, and the largest files are
  ADX music and `motion/*.bin`. So it cannot be skipped as "pre-rendered video".

The dip starts at **t ≈ 37 s after the status file appears in every run**, which
makes it deterministic content rather than host contention. `speed` also swings
between 19 % and 98 % CPU thread utilisation from scene to scene during gameplay,
so short samples of a single scene mean very little.

## What was tried

**Kept — locked-L1 identity window.** The audio ring buffer hammers one 4 KB
page of locked cache (113.6 M accesses / 20 s, segment 0xE, translation always
identity). The host now proves identity across a whole page (checking
`TranslateAddress` at both ends of the page and recording the guest MSR) and the
module serves those accesses inline. `ptr_calls` fell 149.6 M → 23.7 M; speed
0.587 → 0.605. Design constraints, all enforced:

* publish only after host-side proof, never from an assumption about placement;
* record the MSR it was validated under, compare in the module, so an inline
  `mtmsr` disables it on the very next access;
* invalidate on SPR/BAT/TLB/HID writes, cache-control ops, and interpreter
  fallback — not on SPR *reads* (a read cannot change translation, and
  `mfspr DEC/TB` runs in the scheduler tick).

**Kept — dual core** (`[Core] CPUThread = True`): 0.605 → 0.81 (+19 %). The FIFO
layer already supported it; the CPU thread no longer runs the GPU.

**Kept — cached subsystem pointers** in the core, the `CompileExceptionCheck`
early-out (was an `unordered_set` probe per gather burst on an always-empty
block cache), and `TranslateRelAddress` early-out when there are no REL modules.

**Kept — Vulkan `MAILBOX` present mode** with `FIFO` fallback.

**Rejected — `-march=native` on the host**: no gain, and it hides real codegen
problems. The module keeps `-march=native -mtune=native`.

**Rejected — `ImmediateXFBEnable`**: the original measurement (0.721 vs 0.720) is
void. The key lives in `[Hacks]` and it was written to `[Hardware]`, so the loader
ignored it and both arms of that A/B ran with the hack off. Re-run properly on
2026-11-04: `progressive=on, IR=2`, `[Hacks] ImmediateXFBEnable = True` → opening
mean **0.9171**, min 0.5624, 15/50 s below 0.90; `False` → mean **0.9243**, min
0.6217, 14/50 s. No gain, and present count stayed at 50/s either way (the hack
moves the present earlier in the frame, it does not add one). Default (`False`) kept.

**Rejected — forcing the present mode**: `MODERNGEKKO_PRESENT_MODE=fifo|mailbox|immediate`
on the opening all land within noise (mean 0.9228 / 0.9243, 14/50 s below 0.90 for
each) and all report `mean=20.00 ms` present cadence. Pacing is not the problem.

**Rejected — `ForceProgressive = False` as a default**: it does remove the
field-stitch comb, but it hands back 640x264 per present instead of 640x528 (see
*Flicker*), and it changes nothing about speed. Left as a user judgement, not a
default.

**Rejected — `SafeTextureCacheColorSamples = 128`**: 0.808/0.804 vs 0.811
baseline, nothing, and it risks texture mix-ups.

**Rejected — CPU affinity pinning** (CPU thread → core 0, video → core 2):
0.795 vs 0.811. The scheduler already does better than a hand-rolled map.

## 2026-11-07: dispatch pruning, and two theories that died

### Where the CPU thread goes now (997 Hz, gameplay savestate)

26,797 CPU-thread samples, `--load-state states/gameplay-01.state`, speed
0.990 → 1.001. The GPU thread was only ~38 % busy, so the CPU thread is the wall.

| share | what |
|---|---|
| **61.8 %** | generated guest chunk code (`func_*`) |
| **19.1 %** | out-of-line `ppc_*` helpers: `psq_load` 4.2, `ppc_fma` 2.1, `psq_store` 2.0, `ps_madd_op` 1.5, `fmuls` 1.4, `ps_mul_op` 1.3 |
| 8.3 % | other host |
| 6.0 % | chassis (`StaticRecompCore::Run` 3.2 of it) |
| 2.3 % | FIFO / GPFifo on the CPU thread |
| 1.5 % | `HookInstructionFallback` |

Top single symbols: `func_800FD5E0` 14.1, `func_800E55E0` 9.4, `func_800F95E0` 8.5.

**The 19 % in `ppc_*` helpers is the largest identifiable, uncontested block.**
It is out-of-line because the helpers are reachable from ~1,500 memory-op sites
per hot chunk and GCC outlined them (`ppc_psq_load_inline` survives as
`.constprop.2.isra.0`). It is the best remaining codegen target.

### Pruning: 81.9 % of dispatch cases removed, ~3 % of code

`prune_dispatch.py` cuts the per-instruction `case 0xADDR: goto label_ADDR;`
lists from 318,541 to 57,705 entries (17.9 % kept; the hottest chunks keep 15-25 %,
`chunk_0000` keeps 2.8 %). Measured with identical flags on `chunk_0057`:

| | insns | loads | `.text` |
|---|---|---|---|
| original `-O3` | 145,678 | 21,391 | 652,052 B |
| pruned `-O3` (no PGO) | 141,662 | 19,967 | 632,651 B |

That is **2.8 % fewer instructions and 6.7 % fewer loads** — not the 3.5x the
design note predicted. The predicted number (41,505 insns / 6,155 loads / 207 KB)
is **not reproducible** with today's sources and flags, and the earlier
"pruned" `.so` was a PGO build, where `-fprofile-use` spends the freed budget on
unrolling and re-inflates the function 3.5x.

**Why the theory was wrong, and why the metric was wrong too.** The chunk
function is dominated by *cold duplicated slow paths*, not by the switch: the
emitted code inlines the exram check, the locked-L1 window check, the reservation
clear, the write-journal call and the external-access fallback once per guest
memory access (1,472 of them in `chunk_0057`). Those copies make up most of the
35 host instructions per guest instruction, and none of them are hot. Deleting
80 % of the `case` list removes a table that was never the bulk. **Static
instruction counts are therefore a bad proxy for this codegen; only cycles-per-
frame or retired-instructions-per-frame can settle a change.**

### Falsified: the gather-flush call barrier

Hypothesis: `gather_pipe_store()` ends in `cpu->gather_flush(cpu)`, a `CPUState`
function pointer (offset `0xe00`), so every guest store site is a call barrier
that clobbers caller-saved registers; 4,063 `call *0xe00(%rbx)` sites in one
chunk were the spill driver.

Measured by neutering only that call in a throwaway header and rebuilding
`chunk_0057` with identical flags:

| | insns | loads | indirect calls |
|---|---|---|---|
| as-is | 145,678 | 21,391 | 4,179 |
| flush call removed | 146,183 | 22,051 | 3,516 |

Indirect calls fall by 663 and the function gets *bigger*. **Falsified** — the
barrier is not what forces the reloads. Do not spend a rebuild on it. (The real
flush also has to run `GPFifo::CheckGatherPipe`, so it could never be inlined
anyway.)

### A measurement run must never kill a play session

`every tools/*.sh measurement begins with killgame.sh`, and `killgame.sh` used to
SIGTERM whatever `moderngekko-run` it found — including a session being played.
That produced a silently invalid A/B on 2026-11-07 (baseline collected 7 samples
of 110 because the run was stepped on) and, worse, closed the game mid-play.

Fixed: measurement instances are marked `MG_HARNESS=1` (exported by every script
under `tools/` except `play.sh`), and `killgame.sh` reads `/proc/PID/environ` and
**refuses** to touch any instance that lacks the marker, exiting 1 so the caller
aborts instead of measuring a half-dead process. Verified for the four states:
unmarked → refused; mixed → refused (both left alive); marked only → killed;
nothing running → no-op. Never measure with an emulator you did not start.

## 2026-11-08: cross-chunk call chaining, and the NTSC-U recipe gap

PAL's chunks contain `dolrecomp_call_enter` in **all 72 files / 19,353 sites**;
NTSC-U's had **0**. Same game, same runtime, different generation recipe: the
region was recompiled through a path that never set `DOLRECOMP_CHAIN_CALLS=1`,
so every guest `bl` compiled to

```c
ctx->lr = <return addr>;
ctx->pc = <target>;
return;                       // back to the chassis
```

and the target's entry `switch (ctx->pc)` re-dispatched it. The emitter's own
comment prices that round trip: *"two rel-section scans, two IsHostCallAddress
hash lookups, a ModManager dispatch and a downcount flush, none of which a
same-module call needs."* PAL never pays it; NTSC-U paid it on all 18,986
cross-chunk call sites.

Chaining is opt-in and for a good reason (`pipeline.c`): the chassis is the
only place that consults the host-call table, so a module whose addresses a mod
can intercept must stay unchained. Nothing in this build installs host-call
hooks, and PAL ships chained, so the gate is safe here.

The fix, validated before touching the live tree — regenerate into a temp dir
with `DOLRECOMP_CHAIN_CALLS=1` and diff against the pristine snapshot:

    DOLRECOMP_CHAIN_CALLS=1 ./lib/DolRecomp/build/dolrecomp -j6 --backend=c \
      --cpu gekko --gamecube extracted/beach-us/sys/main.dol <artifact>/dolrecomp-output

* file names: identical (same 72-file grid, default `DOLRECOMP_C_CHUNK_INSTRUCTIONS=4096`)
* guest instructions: byte-identical per file (298,691 total)
* labels 292,395 = 292,395, cases 317,567 = 317,567, returns 67,989 = 67,989
* only delta: 18,986 `bl` sites switch to a chained direct call, plus the new
  `dolrecomp` binary's `DOLRECOMP_FHELPER_INLINE` (`always_inline` on
  `dolrecomp_f32_from_bits`/`_to_bits`, a 14-line `generated.h` diff)

Chained form (depth-capped at `DOLRECOMP_C_MAX_CALL_DEPTH 24`; past the cap it
falls back to the chassis, which is always correct because `ctx->pc` already
names the target):

```c
ctx->pc = 0x800E8514u;
if (dolrecomp_call_enter()) {
    void func_800E8514(CPUState* ctx);
    func_800E8514(ctx);
    dolrecomp_call_leave();
    if (ctx->pc == 0x800FD5ECu) goto label_800FD5EC;   // resumed inline
}
return;                          // stopped early: budget/exception/tail-call
```

`dolrecomp_call_depth` is defined in GXRuntime's `core/cpu.c`, so the module
links without extra work. Note the gate is read only by the standalone
`lib/DolRecomp/build/dolrecomp`; the vendor library copy
(`vendor/dolphin/DolRecomp`) never reads it — which is how the US region came
out unchained while PAL did not.

**Region switcher (ImGui, System tab).** PAL / NTSC-U / NTSC-J are offered from
the disc id of the running image (4th char); a region whose game root *or*
module is missing shows as a disabled row rather than a boot-failing selection.
Switching rewrites `--game`/`--module` in argv and `execv`s `/proc/self/exe`
through the existing restart path (dropping `--load-state`, which is
region-specific). NTSC-J has no assets in `extracted/`, so its row stays
disabled until a disc is supplied.

### Recipe gap 2: the runtime entry set was PAL-only

Chaining + PGO + pruning alone made NTSC-U *slower* (0.375 / 22.40 fps vs
0.586 / 34.77 before), and the shutdown counters say why. A pruned switch only
names the addresses the chassis can dispatch to; anything else falls into the
`default:` handler, which runs **one guest instruction through the interpreter
and returns** — so the chassis re-dispatches at pc+4 and repeats until it lands
on a real case. Two counters report it:

| | NTSC-U gameplay | PAL (control) |
|---|---|---|
| `stalls` (dispatch charged 0 cycles) | **121,851,514** | 7,773 |
| `fb_slow` (interpreter fallback) | 121,850,606 | 373 |
| stalls / `native` dispatches | **53 %** | ~0.01 % |
| distinct stall PCs | 3,925 (cap 4096) | 128 |

The trace shows the shape exactly: **1.000 for the first 12 s** (attract), then
0.63 → 0.33 and flat once a match starts. 14 of the top 16 stall PCs had no
`case` at all, each hit 1.77 M times — a hot loop being walked
instruction-by-handler instead of running compiled. Every one of those is a
full chassis round trip, i.e. exactly what chaining exists to remove, so the
holes were *undoing* the chaining win.

Root cause: `build/entries/union.txt` came from a **single PAL capture**
(`build/entries/sources/entries_run1.txt`, 2,012 addresses). NTSC-U's own
dispatch addresses were never collected — 0 of the 512 reported misses were in
it, though all 512 were valid US labels.

The fix is the existing widen loop, made region-aware:

    REGION=GBSE8P ./tools/coverage.sh us-wide1 150   # STATICRECOMP_ENTRY_LOG + [entrymiss]
    ./tools/widen.sh logs/cov-us-wide1-*.entries logs/cov-us-wide1-*.entries.miss
    REGION=GBSE8P ./tools/prunebuild.sh

One capture took the union 2,012 → 5,163 addresses (2,911 new, all valid US
labels) and US cases 58,769 → 61,237 (+4.2 %, still 80.7 % pruned). All 16
known stall PCs became cases. `speed.sh`, `profile.sh` and `coverage.sh` now
take `REGION=`/`GAME=`/`MODULE=` so any region can be measured or captured.

Note the two caps that hide the true size of the problem: `ppc_entry_miss`
reports at most **512** distinct addresses and the stall histogram at most
**4096**, so both logs under-report. `STATICRECOMP_ENTRY_LOG` (what
`coverage.sh` collects) is uncapped and is the authoritative source.

### Training hazard: a stray F1 pauses the run (watchdog added)

`pgo.sh train` had a silent failure mode: **a stray F1 key opens the config
menu, which pauses the runtime**, and the training window is spent paused.
The run still "succeeds" — no error, gcda present, stop command processed —
but the gameplay stage advanced **38 frames instead of ~376**, so the profile
was nearly empty on exactly the paths PGO exists to optimize. Source of the
F1 was a real platform-layer key event (physical keyboard / RustDesk are both
live on this box), not any script; it fired 3 times in one 60 s run.

Fix in `tools/pgo.sh:run_one`: poll `status.txt` `state=` every second (the
automation writer runs on its own thread, so it updates while paused), and
only when our own log shows an unmatched `[menu] Show:` vs `[menu] Hide:`
pair, drop `command=hotkey / keysym=0xFFBE` into the commands dir to close it
again — never a blind F1, which would *open* the menu if something else had
paused us. Debounced 2 s per close.

First run with the watchdog: 3 menu openings caught, gameplay **654 frames**
(vs 38 without, 376 on the old clean run). Symptom to recognize: a training
stage whose `frames` delta is an order of magnitude below the other stage's.

**NTSC-U perf bar is 60 fps, not PAL's 50** — 1.73x the throughput PAL needs.
Pre-fix measurement: 0.586 / 34.77 fps (gameplay, NAV+INPUT+TRACE) against
PAL's 0.971 / 48.71. Chaining + pruning + PGO is the config being measured.

## 2026-11-09: LTO partitioning, the idle-PC probe, and two dead ends

NTSC-J closed the last 0.4 fps and PAL's blind prune was diagnosed. The levers
that mattered, in the order they were found:

**Kept — `-flto=4` instead of bare `-flto`.** The module link was the wall: a
plain `-flto` link serialises LTRANS, and on this 4-core box that was **~85 min
for 4.71 MB of object code** (`lto-wrapper: warning: 132 LTRANS-Aufträge werden
seriell compiliert`). `-flto=4` runs four LTRANS jobs at once: the same build
now takes **~13 min end to end**, and the output is **byte-identical in size**
(46,536,496 B either way) and equally fast. This applies to both
`CMAKE_C_FLAGS` and `CMAKE_SHARED_LINKER_FLAGS`, and it is the default for every
region now.

**Kept — a cheap idle-PC probe in the hot dispatch loop.** `m_idle_pcs` was an
`std::unordered_set` consulted **once per dispatch**, which is absurdly
expensive for a set that has seven members. Replaced with a sorted
`std::vector<u32>` plus a 64-bit bloom (`1ull << ((pc >> 2) & 63)`) and a
one-entry cache of the last hit — a spin loop returns to the dispatcher with the
same pc over and over, so the cache answers almost every real hit and the bloom
rejects everything else in two instructions. **+0.4 fps** on NTSC-J
(59.50 → 59.91), and it is what let the JP build sit at `speed=1.000`.

**Rejected — merging the two PSQ accesses into one 64-bit read.** `sge`/`lq`
with GQR type 0 read two adjacent words; the fast path did two `mem_read32`
with a full `get_ram_ptr` resolve each. Resolving the 8-byte span once and
doing a single `read_be64` did exactly what it promised — `ppc_psq_load_inline`
went from **4.6 % of samples to 0 %** — but the extra inline body inflated every
call site and the net was a loss: 59.65 / 59.72 / 59.78 vs 59.85–59.94.
Reverted. The helper only ever fires for GQR type 0; quantised types still fall
through to `ppc_psq_load`/`ppc_psq_store`, and widening that made it worse.

**Rejected — a blanket idle-PC list.** A scan of every generated chunk found
**71** functions shaped like a spin loop (`mem_read` + `bne` back to self, no
writes, no calls), against the 7 PCs in `StaticRecompIdlePCs`. Configuring all
71 dropped NTSC-J to **56.17** — `CoreTiming::Idle` on loops that also make
forward progress burns the scheduler tick instead of saving it. The 7-PC list
is empirical, not derivable from the loop shape; do not "improve" it by
scanning.

**PAL was pruned against evidence it never had.** `build/entries/union.txt`
came from NTSC-J plus NTSC-U captures only, so the PAL rebuild removed cases
the PAL disc really dispatches to: **253 entry misses** and a drop to
46.68 fps (from 48.71 unpruned). This is the same class of bug as *Recipe gap
2* above — a pruned switch with no case for a reachable pc walks it one
instruction at a time through the interpreter. Fixed by capturing PAL's own
set (`REGION=GBSP8P ./tools/coverage.sh pal-cov1 300`: 5,206 addresses, 512
misses) and widening the union to **19,372 addresses across 16 source files**.
The lesson generalises: **the entry set needs a capture per region**, because
the regions do not share a DOL layout.

Result for the region that was the goal: NTSC-J measured **59.94 / 59.85 /
59.91 / 59.96 fps** with `speed=1.000` on three of four runs, i.e. full NTSC
rate (the field rate the game asks for is 59.94 Hz). Remaining gap is inside
this box's noise.

### A stale profile is a silent 6 % regression, and pruning invalidates it

After the PAL prune landed with real entry data, PAL measured **46.90 fps** —
still worse than the 48.71 it managed *before* pruning, and with stalls down to
67,020 dispatches from 1,883,977. Pruning had done exactly what it should, so
the prune was not the problem. The profiles were: PAL's `.gcda` were dated
**Nov 6** while the chunks were re-pruned **Nov 9**, i.e. the training run had
seen the *unpruned* tree and 77 % of the source had changed underneath it.

`-fprofile-correction` and `-fprofile-partial-training` make that build
*succeed* — they just discard the profile wherever the CFG no longer matches,
which is everywhere. The only visible sign is a wall of `-Wcoverage-mismatch`
warnings that the pipeline normally suppresses.

Re-running the cycle in the right order — **prune, then `pgo.sh generate`,
`train`, `use`** — took PAL from 46.90 to **49.95 / 49.99 / 49.83 fps at
`speed=1.000`**, and the module got *smaller* (51,095,480 → 50,085,552 B)
because the compiler finally had matching data to shrink with.

Two consequences for the pipeline:

* **Never prune a tree that already has profile data and then ship it.** Prune
  first, profile second. The order used to be incidental; it is now the rule.
* `pgo.sh use` builds with `-flto=<n>` (default 4, `LTO=0` disables) so the
  stage that ships is the stage that gets measured. Before this, `use` emitted
  an un-LTO'd module and the shipped artifact came from a manual relink
  afterwards, which is one more chance for the measured module and the shipped
  module to differ.

Do not edit `pgo.sh` while it is running: bash reads a script incrementally from
disk, so rewriting it shifts every later byte offset and the running process
resumes mid-token (`local: can only be used in a function`). The stage's work
still completes; the tail of the script does not.

**The artifact `.so` must be a symlink into `module-build/`.** NTSC-J's artifact
path was a regular file left over from an earlier manual `cp`, so `pgo.sh train`
launched the *optimised* module instead of the instrumented one: the run
finished, reported `speed=0.999` (an instrumented module cannot run at 1.0 — that
was the tell) and produced **zero** `.gcda`. Training now refuses to start unless
the artifact resolves to `module-build/<module>`. Same class of failure as the
stale profile above: nothing errors, the numbers just quietly mean nothing.

### NTSC-U: same fix, same payoff

NTSC-U carried 428 entry misses and a profile trained (02:35) before its prune
(06:15). One capture (`REGION=GBSE8P ./tools/coverage.sh us-cov2 180
--load-state states/gameplay-GBSE8P.state`) contributed 7,702 addresses and took
the union to **25,324**; the re-prune kept 77,647 of 317,567 cases (75.5 %), and
the re-profile took misses **428 → 37** and stalls to 16,946. Measured
**59.94 fps at `speed=1.000`/`1.001`** — exactly the NTSC field rate — twice.

### NTSC-J: matched profile, no change — it is simply at its ceiling

NTSC-J's profile was also 52 min older than its prune, so it got the same cycle
(46,892,728 B, 11m48s). Interleaved A/B against the pre-PGO snapshot:

| run | pre-PGO module | matched-profile module |
|---|---|---|
| 1 | 59.35 | 59.65 |
| 2 | 59.51 | 59.51 |

Identical within noise. Unlike PAL — whose profile was three days and a full
re-prune out of date — JP's mismatch cost nothing measurable, and there is no
regression to undo.

What *is* worth recording is that JP has **no headroom**, unlike the other two
regions. Under the same desktop load (`load average 2.28`; electron, zen and a
remote-desktop client together holding a core) the three regions measured:

| region | target | measured | speed |
|---|---|---|---|
| NTSC-U | 60 Hz | 59.95 | 1.001 |
| PAL | 50 Hz | 49.99 | 1.000 |
| NTSC-J | 60 Hz | 59.74–59.79 | 0.996–0.998 |

JP reads 59.90–59.96 at `speed=1.000` on an idle box (measured four times
earlier in the session) and drops ~0.3 % when the desktop takes a core. So
"JP hits full speed" is true and reproducible, but it is a claim about an
unloaded machine, and it should be stated that way.

Things checked and found not to be the answer:

* **Not an unskipped spin loop.** `STATICRECOMP_DISPATCH_SAMPLES=1` on the
  gameplay state gives a flat profile — the hottest dispatch site holds 1,529 of
  ~75 k samples (~2 %), with no single address behaving like the 7 configured
  idle loops.
* **Not interpreter fallback.** `fb_slow` is 195 for JP and 178 for NTSC-U.
* **Not pinning.** Confining the run to two physical cores with their SMT
  siblings (`PIN=2,3`, `PIN=2,3,6,7` in `speed.sh`) moved JP 59.5 → 59.71 and
  nothing more; the unpinned placement already keeps the two hot threads on
  separate cores 99.2 % of the time (`tools/affinity.sh`).

## 2026-11-13: shipped defaults — dual-core on

The other standing complaint ("bad performance on some machines, a single core
pinned at ~103 %") turned out to be a shipped default, not a bug: desktop
builds had `DEFAULT_CPU_THREAD = false` (single-CPU mode); only Android got
`true`. Single-CPU mode is exactly "one core at ~102 % and ~0.59-0.81x speed";
dual core reaches ~1.00 (table at the top).

| mode | gameplay speed | what the box does |
|---|---|---|
| single CPU (old shipped default) | 0.587 | one core saturated at ~102 % |
| dual core (new shipped default) | 0.81 (~40 fps) | ~1.000 on an idle box |

Why it ships as a compiled default rather than a game ini: the port boots
`main.dol` directly, so Dolphin's game id becomes `ID-main` and
`GetGameIniFilenames()` never matches a `GBS*.ini` — no `[Core]` layer of a
game ini is ever loaded (only the Cheats tab builds those paths by hand in
`config_menu.cpp`). The change is `DEFAULT_CPU_THREAD` in `MainSettings.cpp`;
an explicit `CPUThread` in a user's `Dolphin.ini` still overrides it either
way.

**Module `-O2` vs `-O3` (shipped default): measured 2026-11-14 — no win for
`-O3`, the default stays `-O2`.** Interleaved A/B with `tools/ab_load.sh`
(3 rounds x 110 s per module, `tools/loadhog.sh` holding 2 synthetic
competitors through every run so both sides faced the same stated contention),
metric = `cpf.sh`'s Mcycles/frame (divided by the guest frame counter, so
speed wobble cancels out), modules = clang Release thin-LTO, no PGO, built into
`build/modab/{o2,o3}`:

| module | mean Mcycles/frame per round | p50 | p90 | worst | over 82.0 budget |
|---|---|---|---|---|---|
| `-O2` | 126.54 / 121.07 / 118.04 (avg **121.9**) | 146-152 | 183-189 | 194-257 | 82 / 82 / 82 of 110 s |
| `-O3` | 122.44 / 119.53 / 128.66 (avg **123.5**) | 144-158 | 182-206 | 209-232 | 83 / 82 / 82 of 110 s |

`-O3` won rounds 1-2 by 1-3 % and lost round 3 by 9 %; the aggregate means
differ by 1.4 % in `-O2`'s favour while round-to-round swing reaches 9 %, and
`p90`/`worst` both favour `-O2`. That is noise, not a module effect: ambient
load ran 9.9-11.4 mean (max 15.5, runnable up to 48 on 8 threads) and the
`-O2` rounds happened to sit on the lighter side of it. Every run was over the
82 Mcycles budget because the box was contended, not because of the module —
at load ~1 the same budget clears comfortably (top table). Verdict: no
evidence `-O3` beats `-O2` *without* PGO, so the shipped default stays `-O2`;
the tuned path is unaffected because `tools/pgo.sh` forces
`RECOMPCORE_MODULE_OPT_LEVEL=3` itself (lines 256/382). The earlier ad-hoc
`speed.sh` pairs that appeared to show a big difference were order/content
effects — first run IPC ~0.97-1.01, second run ~0.75-0.77 regardless of which
module ran second — and are not evidence.

Side note (2026-11-14): `tools/perfcount` is a gitignored build artifact and was
missing on this checkout, so every `PERF=1` run silently produced no counters
(the harnesses tolerate its absence, which is why it went unnoticed). Rebuild
with `gcc -O2 -o tools/perfcount tools/perfcount.c` — `perf_event_paranoid=2`
on this box allows user-space counters.

## Remaining levers, by expected value

Done: **PGO + `-O3` for the module** was the big one (0.81 → 0.995).
Done 2026-11-06: **inline gather-pipe stores** (own section above) — pinned
gameplay at 1.000 and halved the opening's deficit.

1. **Matched refresh at native resolution** — the only lever that removes visible
   judder, and it costs nothing but a reboot. `video=HDMI-A-1:2560x1440@100`
   (see *Matched refresh*). Does not change `speed` at all; it changes how evenly
   the 50 Hz frames land on the panel.
2. ~~Inline gather-pipe stores~~ **DONE 2026-11-06** (mmio_gather 555 M → 0;
   gameplay 0.995 → 1.000, opening mean 0.92 → 0.989).
3. **Cache the `PPCState*`** inside `GPFifoManager` instead of resolving it per
   store through the pimpl — was ~1 % of the thread, but the fast path already
   cut host pipe writes ~8x (one drain per 8 stores), so this is now well under
   0.5 % and not worth a cycle on its own.
4. **Trim `StaticRecompCore::Run`** and the per-burst `SyncIn`/`SyncOut` copies,
   plus whatever is left in `ResolveNativeAddress`/`OnICacheInvalidate` after the
   empty-block gate.
5. **Batch `SetCPStatusFromGPU`** in the GPU loop (1.8 %) — upstream Dolphin
   code, higher risk. The GPU loop itself is not a spin (`MainLoop::Run(...,
   100)` yields), so it is not worth touching for its own sake.

At 1.000 gameplay the remaining gap is inside this box's measurement noise
under load, so only pursue 3-5 if a heavier scene is found that drops below
real time; verify any change with two repeats plus `uptime`.

Not achievable (updated 2026-11-06): closing the rest of the opening's slow
phase. The gather fix cut it from 0.63-0.83 (13-15 s below 0.90) to 0.84-0.90
(4 s below 0.90, mean 0.989); what is left is ~1.19x throughput over ~5 s,
still spread across dozens of chunks with no dominant symbol, so there is no
targeted optimisation for it either — just less of it to live with.

## Build / rebuild

Host (~1 min):

    cd lib/ModernGekko && cmake --build build --target moderngekko-run -j6

Module — use the PGO driver, never a bare `ninja`, or the profiles silently
stop applying:

    ./tools/pgo.sh status     # where the cycle is, whether gcda exist
    ./tools/pgo.sh generate   # -fprofile-generate build   (~26 min)
    ./tools/pgo.sh train      # attract 45 s + gameplay 60 s, automation stop
    ./tools/pgo.sh use        # -fprofile-use -O3 build     (~18 min)
    ./tools/pgo.sh restore    # back to the plain baseline .so

The baseline `.so` and the archived `.gcda` set live in `tools/pgo-state/`.
Generation is still Dolphin-side work (`DOLRECOMP_CHAIN_CALLS=1
./lib/DolRecomp/build/dolrecomp -j6 --backend=c --cpu gekko --gamecube
extracted/beach/sys/main.dol <artifact>/dolrecomp-output`), but any chunk
recompile invalidates every `.gcda` because the profiles are keyed by absolute
object path — rebuild and retrain rather than mixing.

Debug switches (both silent by default):

    MODERNGEKKO_AUDIO_DEBUG=1  one `[audio] ...` drift line per second
    MODERNGEKKO_IMGUI_DEBUG=1  one `[imgui] presents/s= vtx=` line per second

**`staticrecomp/CPUState` is defined twice** — GXRuntime's `core/cpu.h` and
ModernGekko's `include/moderngekko/cpu_state.h`. They must stay byte-identical;
the host build has no header dependency on the module header, so a change on one
side silently produces "CPU state size mismatch" at module load (or, worse,
correct-looking but wrong field offsets). Append new fields to both, at the end.
