#!/usr/bin/env python3
"""Resolve profsample output to symbols.

Reads the sample file plus the maps snapshot taken while the process was
alive, then attributes every IP to the containing ELF symbol. Chunk functions
are the interesting ones: the generated module exports one `func_XXXXXXXX` per
chunk, so a chunk's share of samples is (samples inside its address range) /
(total samples).

usage: profsym.py SAMPLES MAPS [--top N] [--per-thread]
"""
import bisect
import os
import re
import subprocess
import sys
from collections import defaultdict


def parse_maps(path):
    """Return list of (start, end, offset, path)."""
    out = []
    with open(path, "r") as fh:
        for line in fh:
            m = re.match(r"^([0-9a-f]+)-([0-9a-f]+) (\S+) ([0-9a-f]+) \S+ \d+\s*(.*)$", line)
            if not m:
                continue
            start, end, _perms, off, name = m.groups()
            out.append((int(start, 16), int(end, 16), int(off, 16), name.strip()))
    return out


def elf_symbols(path):
    """Return sorted (addr, name) list of function symbols in the ELF."""
    try:
        raw = subprocess.run(
            ["nm", "--defined-only", "-n", path],
            capture_output=True, text=True, timeout=120
        ).stdout
    except Exception:
        return []
    syms = []
    for line in raw.splitlines():
        parts = line.split(None, 2)
        if len(parts) < 3:
            continue
        addr, kind, name = parts
        if kind.lower() not in ("t", "w", "i"):
            continue
        try:
            syms.append((int(addr, 16), name))
        except ValueError:
            continue
    syms.sort()
    return syms


def lookup(syms, addrs, off):
    """Name of the symbol containing `off`, or None."""
    i = bisect.bisect_right(addrs, off) - 1
    if i < 0:
        return None
    return syms[i][1]


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 1
    samples_path, maps_path = sys.argv[1], sys.argv[2]
    top_n = 25
    per_thread = "--per-thread" in sys.argv
    if "--top" in sys.argv:
        top_n = int(sys.argv[sys.argv.index("--top") + 1])

    maps = parse_maps(maps_path)
    # Only executable mappings can hold sampled IPs.
    exec_maps = [m for m in maps]
    starts = [m[0] for m in exec_maps]

    symcache = {}
    totals = defaultdict(int)
    for line in open(samples_path):
        parts = line.split()
        if len(parts) != 3:
            continue
        count, tid, ip = int(parts[0]), int(parts[1]), int(parts[2], 16)

        i = bisect.bisect_right(starts, ip) - 1
        label = None
        if i >= 0 and ip < exec_maps[i][1]:
            start, _end, moff, name = exec_maps[i]
            if name.startswith("/") and os.path.exists(name):
                if name not in symcache:
                    symcache[name] = (elf_symbols(name), None)
                syms = symcache[name][0]
                if syms:
                    addrs = [s[0] for s in syms]
                    sym = lookup(syms, addrs, ip - start + moff)
                    if sym:
                        label = f"{sym}  [{os.path.basename(name)}]"
                if label is None:
                    label = f"+0x{ip - start + moff:x}  [{os.path.basename(name)}]"
            elif name:
                label = f"{name}+0x{ip - start + moff:x}"
        if label is None:
            label = f"<unknown 0x{ip:x}>"
        key = (tid, label) if per_thread else label
        totals[key] += count

    grand = 0
    for line in open(samples_path):
        parts = line.split()
        if len(parts) == 3:
            grand += int(parts[0])
    print(f"total samples: {grand}\n")

    if per_thread:
        for (tid, label), count in sorted(totals.items(), key=lambda kv: -kv[1])[:top_n]:
            print(f"{count:7d} {100.0*count/grand:5.1f}%  tid={tid:<8} {label}")
    else:
        for label, count in sorted(totals.items(), key=lambda kv: -kv[1])[:top_n]:
            print(f"{count:7d} {100.0*count/grand:5.1f}%  {label}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
