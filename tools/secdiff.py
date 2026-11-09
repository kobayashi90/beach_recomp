#!/usr/bin/env python3
"""Diff the CPU thread's profile between seconds of a secprof.sh run.

Aggregate profiles ("where the time goes") blend fast and slow content, so they
cannot answer "why was second 10 slow". secprof.sh already samples one second at
a time and records the emulator's own speed per second; this compares a slow
second against a fast one and reports the difference in *absolute* sample counts.

Absolute counts matter more than percentages here: a symbol whose percentage is
unchanged but whose count doubled is doing twice the work, which is a completely
different problem from a symbol that became slower per call.

usage: secdiff.py <base-without-extension> <cpu-tid> [--fast N] [--slow N]
"""
import bisect
import os
import sys
from collections import Counter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import profsym


def build_labeller(maps_path):
    maps = profsym.parse_maps(maps_path)
    starts = [m[0] for m in maps]
    symcache = {}

    def label_for(ip):
        i = bisect.bisect_right(starts, ip) - 1
        if i < 0 or ip >= maps[i][1]:
            return None
        start, _end, moff, name = maps[i]
        if not name.startswith("/") or not os.path.exists(name):
            return name or None
        if name not in symcache:
            syms = profsym.elf_symbols(name)
            symcache[name] = (syms, [s[0] for s in syms])
        syms, addrs = symcache[name]
        sym = profsym.lookup(syms, addrs, ip - start + moff) if syms else None
        return f"{sym} [{os.path.basename(name)}]" if sym else None

    return label_for


def counts_for(samples_path, cpu_tid, label_for):
    counts = Counter()
    total = 0
    with open(samples_path) as fh:
        for line in fh:
            parts = line.split()
            if len(parts) != 3 or parts[1] != cpu_tid:
                continue
            n = int(parts[0])
            total += n
            lab = label_for(int(parts[2], 16))
            if lab:
                counts[lab] += n
    return counts, total


def main():
    base = sys.argv[1]
    cpu_tid = sys.argv[2]
    speeds = {}
    speed_path = base + ".speed"
    with open(speed_path) as fh:
        for line in fh:
            parts = line.split()
            if len(parts) == 2:
                speeds[parts[0]] = float(parts[1])

    slow_t = int(sys.argv[sys.argv.index("--slow") + 1]) if "--slow" in sys.argv else \
        min(speeds, key=lambda k: speeds[k])
    fast_t = int(sys.argv[sys.argv.index("--fast") + 1]) if "--fast" in sys.argv else \
        max(speeds, key=lambda k: speeds[k])

    label_for = build_labeller(base + ".maps")
    slow, slow_total = counts_for(f"{base}.{slow_t}.samples", cpu_tid, label_for)
    fast, fast_total = counts_for(f"{base}.{fast_t}.samples", cpu_tid, label_for)

    print(f"slow second t={slow_t} speed={speeds.get(str(slow_t), '?')}  "
          f"cpu samples={slow_total}")
    print(f"fast second t={fast_t} speed={speeds.get(str(fast_t), '?')}  "
          f"cpu samples={fast_total}")
    if fast_total and slow_total:
        print(f"slow/fast total work ratio: {slow_total / fast_total:.2f}x\n")

    rows = []
    for name in set(slow) | set(fast):
        s, f = slow.get(name, 0), fast.get(name, 0)
        rows.append((s - f, s, f, name))
    rows.sort(reverse=True)

    print(f"{'delta':>7} {'slow':>6} {'fast':>6}  symbol")
    print("--- grew in the slow second (absolute count) ---")
    for d, s, f, name in rows[:18]:
        if d <= 0:
            break
        print(f"{d:7d} {s:6d} {f:6d}  {name}")
    print("--- shrank in the slow second ---")
    for d, s, f, name in rows[-8:]:
        if d >= 0:
            continue
        print(f"{d:7d} {s:6d} {f:6d}  {name}")


main()
