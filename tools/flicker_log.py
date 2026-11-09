#!/usr/bin/env python3
"""Diagnose presentation flicker from the per-present swapdump log.

Why not the PGM files
---------------------
MODERNGEKKO_SWAP_DUMP_FILES only writes a frame when its luma hash differs from
the immediately preceding *written* frame, so a static screen collapses and the
distance between two saved images no longer means "one present". Any flicker
metric computed on those files mixes present distance with an unknown number of
skipped presents.

The `[swapdump] i=... hash=... mean=... vdiff=...` stderr line is emitted for
every present, before that filter, so it is the honest sequence the display was
shown: one line per present, in order, with:

  hash   FNV of the luma plane -- equality means pixel-identical picture
  mean   average luma -- parity here is a global brightness flicker
  vdiff  mean vertical neighbour disagreement -- a comb/interlace signature
  addr   XFB address the frame was copied from
  copy   per-XFB copy sequence number, for spotting a stale copy

Usage:
  fancy_flicker_log.py LOGFILE [--from N] [--to M]
"""
import argparse
import re
import statistics
import sys

LINE = re.compile(
    r"\[swapdump\] i=(\d+) (\d+)x(\d+) hash=([0-9a-f]+) mean=([\d.]+) "
    r"vdiff=([\d.]+) addr=([0-9a-f]+) copy=(\d+) total=(\d+)")


def parse(path):
    out = []
    for line in open(path, errors="replace"):
        m = LINE.search(line)
        if m:
            out.append(dict(
                i=int(m.group(1)), w=int(m.group(2)), h=int(m.group(3)),
                hash=m.group(4), mean=float(m.group(5)), vdiff=float(m.group(6)),
                addr=m.group(7), copy=int(m.group(8)), total=int(m.group(9))))
    return out


def runs(values):
    """Lengths of consecutive equal-value runs, in order."""
    if not values:
        return []
    lens = []
    cur = 1
    for a, b in zip(values, values[1:]):
        if a == b:
            cur += 1
        else:
            lens.append(cur)
            cur = 1
    lens.append(cur)
    return lens


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("log")
    ap.add_argument("--from", dest="lo", type=int, default=0)
    ap.add_argument("--to", dest="hi", type=int, default=None)
    args = ap.parse_args()

    recs = parse(args.log)
    if not recs:
        print(f"{args.log}: no [swapdump] present lines")
        return 1
    lo = args.lo
    hi = args.hi if args.hi is not None else recs[-1]["i"] + 1
    recs = [r for r in recs if lo <= r["i"] < hi]
    if len(recs) < 8:
        print(f"{args.log}: only {len(recs)} presents in range, too few")
        return 1

    n = len(recs)
    hashes = [r["hash"] for r in recs]
    means = [r["mean"] for r in recs]
    vdiffs = [r["vdiff"] for r in recs]
    res = {(r["w"], r["h"]) for r in recs}

    print(f"{args.log}: {n} presents  i={recs[0]['i']}..{recs[-1]['i']}  "
          f"res={sorted(res)}")

    # 1. Duplicated presents: the same picture handed to the display twice.
    rl = runs(hashes)
    dup = sum(k - 1 for k in rl if k > 1)
    print(f"repeated presents (identical hash to previous): {dup} "
          f"({100.0 * dup / max(n - 1, 1):.1f}% of transitions)")
    hist = {}
    for k in rl:
        hist[k] = hist.get(k, 0) + 1
    print("  run-length histogram: " +
          "  ".join(f"{k}x:{v}" for k, v in sorted(hist.items())))

    # 2. Period-2 alternation: A B A B, i.e. two interleaved pictures.
    alt = sum(1 for j in range(n - 2)
              if hashes[j] == hashes[j + 2] and hashes[j] != hashes[j + 1])
    print(f"period-2 hash alternation (h[i]==h[i+2]!=h[i+1]): {alt} "
          f"({100.0 * alt / max(n - 2, 1):.1f}% of triples)")

    # 3. Autocorrelation of "did the picture change" at each lag. A stream that
    #    flickers between two states has a strong lag-2 peak; honest motion at
    #    50 Hz decays smoothly.
    changed = [1 if hashes[j] != hashes[j - 1] else 0 for j in range(1, n)]
    means_c = statistics.fmean(changed) if changed else 0.0
    print("  hash-change autocorrelation (motion periodicity):")
    for lag in range(1, 9):
        pairs = [(changed[j], changed[j + lag])
                 for j in range(len(changed) - lag)]
        if not pairs:
            continue
        num = statistics.fmean(a * b for a, b in pairs) - means_c * means_c
        a_var = statistics.fmean(a * a for a, _ in pairs) - means_c * means_c
        b_var = statistics.fmean(b * b for _, b in pairs) - means_c * means_c
        den = (a_var * b_var) ** 0.5
        r = num / den if den > 1e-12 else 0.0
        bar = "#" * int(round(abs(r) * 30))
        print(f"    lag {lag}: {r:+.3f} {bar}")

    # 4. Brightness parity: a global flicker alternates frame brightness.
    ev = [means[j] for j in range(0, n, 2)]
    od = [means[j] for j in range(1, n, 2)]
    parity = abs(statistics.fmean(ev) - statistics.fmean(od))
    drift = statistics.fmean(abs(b - a) for a, b in zip(means, means[1:]))
    print(f"brightness: even {statistics.fmean(ev):.3f}  odd {statistics.fmean(od):.3f}  "
          f"parity {parity:.3f}  mean step {drift:.3f}  "
          f"ratio {parity / drift if drift > 1e-9 else 0.0:.3f}")

    # 5. Comb score per present: vertical-neighbour disagreement. Rising vdiff on
    #    every other present is the interlace/weave signature.
    ev = [vdiffs[j] for j in range(0, n, 2)]
    od = [vdiffs[j] for j in range(1, n, 2)]
    parity = abs(statistics.fmean(ev) - statistics.fmean(od))
    drift = statistics.fmean(abs(b - a) for a, b in zip(vdiffs, vdiffs[1:]))
    print(f"comb (vdiff): even {statistics.fmean(ev):.3f}  odd {statistics.fmean(od):.3f}  "
          f"parity {parity:.3f}  mean step {drift:.3f}  "
          f"ratio {parity / drift if drift > 1e-9 else 0.0:.3f}")

    # 6. Stale copies: the same XFB copy sequence number presented more than once
    #    means the presenter is re-showing a picture the guest already replaced.
    copies = [r["copy"] for r in recs]
    crl = runs(copies)
    repeat = sum(k - 1 for k in crl if k > 1)
    print(f"same XFB copy presented repeatedly: {repeat} presents "
          f"({100.0 * repeat / max(n - 1, 1):.1f}%)")

    # 7. XFB address churn, which is how a double-buffered weave shows itself.
    addrs = [r["addr"] for r in recs]
    arl = runs(addrs)
    print(f"XFB address runs: {sorted({k for k in arl})[:8]}  "
          f"distinct addresses {len(set(addrs))}")

    # 8. The transitions with the largest brightness jump: where to look.
    steps = sorted(((abs(means[j] - means[j - 1]), recs[j]["i"], means[j - 1], means[j])
                    for j in range(1, n)), reverse=True)[:6]
    print("largest brightness steps (|dmean|, present, before -> after):")
    for d, i, a, b in steps:
        print(f"    {d:7.3f}  i={i:<6d} {a:7.3f} -> {b:7.3f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
