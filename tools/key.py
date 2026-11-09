#!/usr/bin/env python3
"""key.py KEY [KEY ...] -- send keystrokes through a virtual uinput keyboard.

The emulator is a native Wayland client; xdotool cannot reach it and the
window manager only forwards real (kernel-level) input. /dev/uinput is
writable by this user, so a throwaway virtual keyboard works for any client,
Wayland or X11.

Name a key with its evdev name minus the KEY_ prefix (f1, esc, enter, up,
space, a, 1, leftshift). Add "+"-separated modifiers, e.g. "leftctrl+a".
Timing is deliberately slow: KWin needs a moment to enumerate the device and
focus state changes are asynchronous.
"""
import sys
import time

import evdev
from evdev import ecodes

SETTLE = 0.35  # let KWin enumerate the new device before typing


def resolve(name):
    key = name.strip().upper()
    if not key.startswith("KEY_"):
        key = "KEY_" + key
    code = getattr(ecodes, key, None)
    if code is None:
        raise SystemExit(f"unknown key: {name}")
    return code


def main(argv):
    if not argv:
        raise SystemExit(__doc__)

    # The capability list must be non-empty: a device that advertises EV_KEY
    # with no key codes is ignored by libinput, so KWin never routes anything
    # from it and the client sees silence. Claim the whole keyboard range.
    capabilities = [c for c in range(1, ecodes.KEY_MAX + 1) if c in ecodes.ecodes.values()]
    dev = evdev.UInput(name="moderngekko-test-kbd",
                       events={ecodes.EV_KEY: sorted(set(capabilities))})
    try:
        time.sleep(SETTLE)
        for combo in argv:
            parts = combo.split("+")
            codes = [resolve(p) for p in parts]
            for c in codes:
                dev.write(ecodes.EV_KEY, c, 1)
            dev.syn()
            time.sleep(0.05)
            for c in reversed(codes):
                dev.write(ecodes.EV_KEY, c, 0)
            dev.syn()
            print(f"sent {combo}")
            time.sleep(0.15)
    finally:
        time.sleep(0.1)
        dev.close()


if __name__ == "__main__":
    main(sys.argv[1:])
