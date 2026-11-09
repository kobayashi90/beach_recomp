#!/usr/bin/env python3
"""Snapshot the binaries a profile ran with and repoint the saved maps at them.

A saved /proc/<pid>/maps is only useful while the executables it names are
byte-identical: a rebuild moves every symbol, and resolving old samples against
a new binary silently prints the *wrong* names (they look plausible, which is
worse than failing). Copy the interesting mappings next to the profile and
rewrite the snapshot so it keeps resolving forever.

Usage: profsnap.py <maps-file> <blob-dir> [root ...]
Only paths under one of the given roots are snapshotted; system libraries are
left alone (they do not change underfoot the way our build tree does).
"""
import hashlib
import os
import shutil
import sys


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2
    maps_path, blob_dir = sys.argv[1], sys.argv[2]
    roots = sys.argv[3:]

    os.makedirs(blob_dir, exist_ok=True)
    copied = {}
    out = []
    with open(maps_path) as f:
        for line in f:
            fields = line.split()
            if len(fields) < 6:
                out.append(line)
                continue
            path = " ".join(fields[5:])
            if path.startswith("/") and any(path.startswith(r) for r in roots):
                if path not in copied and os.path.exists(path):
                    digest = hashlib.md5(path.encode()).hexdigest()[:8]
                    dest = os.path.join(blob_dir, f"{digest}-{os.path.basename(path)}")
                    try:
                        if not os.path.exists(dest):
                            shutil.copy2(path, dest)
                        copied[path] = dest
                    except OSError as exc:
                        print(f"profsnap: cannot copy {path}: {exc}", file=sys.stderr)
                if path in copied:
                    out.append(" ".join(fields[:5]) + " " + copied[path] + "\n")
                    continue
            out.append(line)

    with open(maps_path, "w") as f:
        f.writelines(out)
    for src, dst in copied.items():
        print(f"profsnap: {src} -> {dst}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
