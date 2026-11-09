#!/usr/bin/env python3
"""Prune the per-instruction dispatch case list in DolRecomp's generated chunks.

Why
---
DolRecomp emits every guest instruction as its own `case 0xADDR: goto label_ADDR;`
in two switches at the top and at `return_dispatch_*` of every chunk function.
The entry switch names all ~4000 instructions of the chunk, which makes every
label reachable from an indirect jump, so GCC must keep the whole guest register
file in memory: `ctx->gpr[N]` never lives in a host register and every
instruction reloads/stores its operands. Measured on the shipped module: 6 host
instructions per ALU op, 14 per load, 30 per store, 35 per guest instruction.

If the switch only names the addresses the chassis can really dispatch to, the
remaining labels are ordinary C labels and the compiler may allocate registers
across them.

What counts as an entry
-----------------------
A chunk function is entered in exactly three ways:

  1. the chassis calls the module dispatcher with an arbitrary u32 pc; that
     lands on a chunk function, which must accept that pc in its entry switch;
  2. a cross-chunk call site emits `ctx->pc = TARGET; ... func_X(ctx);` so the
     callee must accept TARGET, which is usually a mid-chunk address;
  3. a call returns and the emitter resumes locally with
     `if (ctx->pc == NEXT) goto label_NEXT;` -- NEXT is a local label, no entry
     needed, but if the callee redirected elsewhere the pc is dynamic (case 1).

So the static set is every immediate that can be *live in ctx->pc at a point
where the chunk function returns to the chassis*, plus every `ctx->lr = ADDR`
immediate (indirect returns, reached through case 1), plus every chunk base.

That set cannot cover computed branch targets (`ctx->pc = target; return;` for a
guest jump table) or self-modifying-code addresses, so the pruner also unions a
runtime-observed set: STATICRECOMP_ENTRY_LOG in the chassis records every
address handed to the module dispatcher and dumps it at shutdown. Pass that file
with --entry-extra.

Usage
-----
  prune_dispatch.py CHUNKS_DIR --report
  prune_dispatch.py CHUNKS_DIR --backup /tmp/chunks_orig --entry-extra entries.txt
  prune_dispatch.py CHUNKS_DIR --restore /tmp/chunks_orig
"""
import argparse
import os
import re
import shutil
import sys

CASE_RE = re.compile(r'^\s*case 0x([0-9A-F]{8})u: goto label_([0-9A-F]{8});$')
LABEL_RE = re.compile(r'^label_([0-9A-F]{8}):\s*$')
FUNC_RE = re.compile(r'^void func_([0-9A-F]{8})\(CPUState\* ctx\) \{', re.M)
# `ctx->pc = 0xADDR;` -- the value that may be live at the next return.
PC_SET_RE = re.compile(r'ctx->pc = 0x([0-9A-F]{8})u;')
LR_SET_RE = re.compile(r'ctx->lr = 0x([0-9A-F]{8})u;')
PC_EQ_RE = re.compile(r'ctx->pc == 0x([0-9A-F]{8})u')
SWITCH_RE = re.compile(r'^\s*switch \(ctx->pc\) \{\s*$')
DEFAULT_RE = re.compile(r'^\s*default: return;\s*$')

# Lines that, following a `ctx->pc = VALUE;`, mean that VALUE can be observed by
# the chassis. Anything else means the value is consumed locally.
ENTRY_AFTER_PC_SET = ('return;', 'if (dolrecomp_call_enter())')
KEEP_PC_EQ = True


def analyse(path):
    """Return (base, labels, static_entries, ret_cases) for one chunk file.

    `static_entries` is *global* by nature -- a `ctx->pc = TARGET` in this chunk
    can name a label in a completely different chunk (cross-chunk call) -- so the
    caller unions it across all files before filtering by label.
    """
    text = open(path).read()
    lines = text.split('\n')
    m = FUNC_RE.search(text)
    base = int(m.group(1), 16) if m else None

    labels = set()
    entries = set()
    ret_cases = set()
    after_return_dispatch = False
    for line in lines:
        lm = LABEL_RE.match(line)
        if lm:
            labels.add(int(lm.group(1), 16))
        if line.lstrip().startswith('return_dispatch_'):
            after_return_dispatch = True
        cm = CASE_RE.match(line)
        if cm and after_return_dispatch:
            # The internal re-dispatch switch is reached by `goto return_dispatch_*`
            # after a computed branch. Its cases must survive: dropping one would
            # send the chassis to a pc this chunk can no longer accept.
            ret_cases.add(int(cm.group(1), 16))
        for a in LR_SET_RE.findall(line):
            # An indirect return lands here after `blr`; the chassis dispatches it.
            entries.add(int(a, 16))
        if KEEP_PC_EQ:
            for a in PC_EQ_RE.findall(line):
                # Local fast-resume check after a call. Not strictly an entry,
                # but keeping it costs one case and removes a class of risk.
                entries.add(int(a, 16))

    # State machine: walk forward from each `ctx->pc = VALUE;` to see whether the
    # value escapes to the chassis before it is overwritten or used locally.
    n = len(lines)
    i = 0
    while i < n:
        sm = PC_SET_RE.search(lines[i])
        if not sm:
            i += 1
            continue
        value = int(sm.group(1), 16)
        j = i + 1
        escaped = False
        while j < n:
            nxt = lines[j].strip()
            if not nxt or nxt.startswith('//') or nxt.startswith('/*'):
                j += 1
                continue
            if nxt.startswith('return;') or nxt.startswith('if (dolrecomp_call_enter())'):
                escaped = True
            # `if (ctx->pc == X) goto label_X;` resumes locally: not an entry.
            # `goto return_dispatch_*` is the internal dispatcher: not an entry.
            # `ppc_fallback_instruction(...)` decides pc itself: not this value.
            break
        if escaped:
            entries.add(value)
        i += 1

    if base is not None:
        entries.add(base)
    return base, labels, entries, ret_cases


def rewrite(path, keep, report_only, default_fallback=False):
    lines = open(path).read().split('\n')
    out = []
    old = new = 0
    inside = False
    seen_entry_default = False
    for line in lines:
        if SWITCH_RE.match(line):
            inside = True
            out.append(line)
            continue
        if inside:
            if CASE_RE.match(line):
                old += 1
                addr = int(CASE_RE.match(line).group(1), 16)
                if addr in keep:
                    out.append('    case 0x%08Xu: goto label_%08X;' % (addr, addr))
                    new += 1
                continue
            if DEFAULT_RE.match(line):
                inside = False
                if not seen_entry_default:
                    seen_entry_default = True
                    if default_fallback:
                        # A pruned entry point: execute the single guest
                        # instruction through the interpreter instead of
                        # returning with pc unchanged, which would re-dispatch
                        # the same address until the timeslice expired.
                        out.append('    default:')
                        out.append('        ppc_entry_miss(ctx->pc);')
                        out.append('        ppc_fallback_instruction(ctx, mem_read32(ctx, ctx->pc), ctx->pc);')
                        out.append('        return;')
                        continue
                out.append(line)
                continue
        out.append(line)
    if not report_only:
        with open(path, 'w') as f:
            f.write('\n'.join(out))
    return old, new


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('chunks_dir')
    ap.add_argument('--report', action='store_true')
    ap.add_argument('--backup')
    ap.add_argument('--restore')
    ap.add_argument('--entry-extra', action='append', default=[])
    ap.add_argument('--verbose', action='store_true')
    ap.add_argument('--default-fallback', action='store_true',
                    help='make an unlisted entry run through the interpreter instead of spinning')
    ap.add_argument('--drop-pc-eq', action='store_true',
                    help='do not treat `ctx->pc == X` as an entry (tighter, riskier)')
    args = ap.parse_args()
    global KEEP_PC_EQ
    KEEP_PC_EQ = not args.drop_pc_eq

    if args.restore:
        shutil.rmtree(args.chunks_dir)
        shutil.copytree(args.restore, args.chunks_dir)
        print('restored %s from %s' % (args.chunks_dir, args.restore))
        return 0
    if args.backup:
        if os.path.exists(args.backup):
            shutil.rmtree(args.backup)
        shutil.copytree(args.chunks_dir, args.backup)
        print('backed up to %s' % args.backup)

    files = sorted(os.path.join(args.chunks_dir, f) for f in os.listdir(args.chunks_dir)
                   if f.startswith('chunk_') and f.endswith('.c'))
    if not files:
        print('no chunk files in %s' % args.chunks_dir)
        return 1

    runtime = set()
    for path in args.entry_extra:
        for line in open(path):
            line = line.strip()
            if line:
                runtime.add(int(line, 16))

    tot_old = tot_new = 0
    missing_base = 0
    widest = []
    analysed = []
    global_entries = set()
    for path in files:
        base, labels, entries, ret_cases = analyse(path)
        if base is None:
            print('!! no func_ definition in %s' % path)
            missing_base += 1
            continue
        analysed.append((path, labels, ret_cases, entries))
        global_entries |= entries

    for path, labels, ret_cases, entries in analysed:
        keep = {a for a in (global_entries | runtime | ret_cases) if a in labels}
        old, new = rewrite(path, keep, args.report, args.default_fallback)
        tot_old += old
        tot_new += new
        if args.verbose and old != new:
            widest.append((old - new, os.path.basename(path), old, new))

    print('cases: %d -> %d  (%.1f%% pruned)%s'
          % (tot_old, tot_new,
             100.0 * (tot_old - tot_new) / max(tot_old, 1),
             '  [report only]' if args.report else ''))
    print('runtime-observed entry addresses: %d' % len(runtime))
    if missing_base:
        print('!! %d chunk files had no func_ definition' % missing_base)
    if args.verbose:
        widest.sort(reverse=True)
        for gone, name, old, new in widest[:12]:
            print('  %-42s %5d -> %5d' % (name, old, new))
    return 0


if __name__ == '__main__':
    sys.exit(main())
