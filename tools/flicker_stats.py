#!/usr/bin/env python3
"""Score a directory of MODERNGEKKO_SWAP_DUMP PGMs for the intro-flicker shape.

The one number that decides the diagnosis is the ratio d(i,i+2)/d(i,i+1) over
frames that are actually animating:

  * ~2.0  normal 50 Hz motion: the picture moves a step per present, so two
          presents apart is about twice as far
  * ~0.0  two interleaved streams: consecutive presents are far apart while
          every other present is nearly identical

Anything in between is a mix, so the ratio is reported per stretch.
"""
import glob
import statistics
import sys

import numpy as np
from PIL import Image


def load(path):
    return np.asarray(Image.open(path), dtype=np.int16)


def main(directory, motion_floor=0.05):
    files = sorted(glob.glob(f"{directory}/swap-*.pgm"))
    if len(files) < 6:
        print(f"{directory}: only {len(files)} frames, skipping")
        return
    frames = [load(f) for f in files]
    n = len(frames)
    # d1[j] is the distance across one present, d2[j] across two, both anchored
    # at frame j, so the ratio must pair them on the same index.
    d1 = [float(np.abs(frames[j + 1] - frames[j]).mean()) for j in range(n - 1)]
    d2 = [float(np.abs(frames[j + 2] - frames[j]).mean()) for j in range(n - 2)]

    ratios = [d2[j] / d1[j] for j in range(n - 2) if d1[j] > motion_floor]
    alt = sum(1 for r in ratios if r < 0.5)
    norm = sum(1 for r in ratios if r > 1.2)

    def comb(a):
        c, up, dn = a[1:-1, :], a[:-2, :], a[2:, :]
        nearby = np.abs(up - dn) <= 2
        jump = np.minimum(np.abs(c - up), np.abs(c - dn)) >= 8
        return float(np.mean(nearby & jump))

    evens = [d1[j] for j in range(0, n - 1, 2) if d1[j] > motion_floor]
    odds = [d1[j] for j in range(1, n - 1, 2) if d1[j] > motion_floor]

    print(f"{directory}: {n} unique presented frames")
    if ratios:
        print(f"  animating transitions: {len(ratios)}  median d(i,i+2)/d(i,i+1) = "
              f"{statistics.median(ratios):.3f}")
        print(f"  alternating steps (ratio<0.5): {alt}   normal steps (>1.2): {norm}")
        print(f"  d1 median {statistics.median(d1):.3f}  max {max(d1):.3f}")
        if evens and odds:
            print(f"  even-index d1 median {statistics.median(evens):.3f}  "
                  f"odd-index d1 median {statistics.median(odds):.3f}")
    else:
        print("  no motion above the floor")
    print(f"  comb score max over all frames: {max(comb(f) for f in frames):.4f}")

    # A full-frame average hides a flicker that lives in one band, so locate the
    # band: rows where one-present motion is large but two-present motion is not
    # are the rows whose content alternates between two states.
    stack = np.stack(frames).astype(np.float32)
    row_d1 = np.abs(stack[1:] - stack[:-1]).mean(axis=(0, 2))
    row_d2 = np.abs(stack[2:] - stack[:-2]).mean(axis=(0, 2))
    order = np.argsort(row_d1)[::-1][:5]
    print("  busiest rows (row: d1, d2, d2/d1)")
    for r in order:
        print(f"    {int(r):4d}: {row_d1[r]:6.2f} {row_d2[r]:6.2f}  {row_d2[r] / max(row_d1[r], 1e-9):6.3f}")

    # Even/odd present brightness. Two interleaved streams show up as a large
    # parity amplitude compared with the frame-to-frame brightness change.
    bright = stack.mean(axis=(1, 2))
    parity = float(abs(bright[0::2].mean() - bright[1::2].mean()))
    drift = float(np.abs(np.diff(bright)).mean())
    print(f"  brightness parity even-vs-odd {parity:.3f}  mean frame-to-frame drift {drift:.3f}")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "logs/swapdump")
