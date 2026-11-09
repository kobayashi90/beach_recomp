#!/usr/bin/env python3
"""Parse gdb backtraces from /tmp/mg-s1.txt, resolve ?? addresses via /proc/PID/maps."""
import re, collections, sys

pid, path = sys.argv[1], sys.argv[2]

maps = []
with open(f'/proc/{pid}/maps') as f:
    for line in f:
        parts = line.split()
        a, b = parts[0].split('-')
        maps.append((int(a, 16), int(b, 16), int(parts[2], 16),
                     parts[5] if len(parts) > 5 else '[anon]'))

def resolve(addr):
    for s, e, o, p in maps:
        if s <= addr < e:
            if p.startswith('/'):
                return p.rsplit('/', 1)[-1] + f'+0x{addr-s+o:x}'
            return p
    return 'unmapped'

frame_re = re.compile(r'^#(\d+)\s+(0x[0-9a-f]+)(?: in (.*))?$')
samples = []
cur = None
with open(path, errors='replace') as f:
    for line in f:
        line = line.rstrip('\n')
        m = re.match(r'^===== sample (\d+) =====', line)
        if m:
            cur = []
            samples.append(cur)
            continue
        if cur is None:
            continue
        fm = frame_re.match(line.strip())
        if fm:
            num = int(fm.group(1))
            addr = int(fm.group(2), 16)
            sym = (fm.group(3) or '?').strip()
            if num == 0 and cur:      # duplicate backtrace in same sample -> ignore
                continue
            cur.append((num, addr, sym))

print(f'samples parsed: {len(samples)}, with frames: {sum(1 for s in samples if s)}')

def classify(num, addr, sym):
    if sym and not sym.startswith('??') and sym != '?':
        # keep the function name; for 'X from lib' keep lib hint
        if ' from ' in sym:
            fn, lib = sym.split(' from ', 1)
            return fn.rstrip(' ()') + ' @ ' + lib.strip()
        return sym.rstrip(' ()')
    return resolve(addr)

leaf = collections.Counter()
frame0 = collections.Counter()
anywhere = collections.Counter()
uniq_q = collections.Counter()
depths = []
for s in samples:
    if not s:
        continue
    depths.append(len(s))
    num, addr, sym = s[-1]
    leaf[classify(num, addr, sym)] += 1
    num, addr, sym = s[0]
    frame0[classify(num, addr, sym)] += 1
    seen = set()
    for num, addr, sym in s:
        c = classify(num, addr, sym)
        if c not in seen:
            anywhere[c] += 1
            seen.add(c)
        if sym and sym.startswith('??'):
            uniq_q[resolve(addr)] += 1

print(f'\n== frame depth: min {min(depths)} max {max(depths)} avg {sum(depths)/len(depths):.1f}')

print('\n== LEAF (deepest frame) frequency, top 20 ==')
for k, v in leaf.most_common(20):
    print(f'{v:4d}  {k}')

print('\n== FRAME0 frequency, top 15 ==')
for k, v in frame0.most_common(15):
    print(f'{v:4d}  {k}')

print('\n== appears anywhere in stack (sample count), top 25 ==')
for k, v in anywhere.most_common(25):
    print(f'{v:4d}  {k}')

print('\n== resolved ?? addresses (any frame) ==')
for k, v in uniq_q.most_common(15):
    print(f'{v:4d}  {k}')
